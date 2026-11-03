// SPDX-License-Identifier: CC0-1.0
/* Based on Espressif eppp_link/examples/slave, pinned source in cache/sources.json.
 * SoftAP plus explicit SSH TCP relay replaces the example's STA/outbound NAPT.
 */
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "freertos/task.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_random.h"
#include "esp_wifi.h"
#include "nvs_flash.h"
#include "lwip/sockets.h"
#include "eppp_link.h"
#include "wifi_credentials.h"
#include "tcp_relay.h"

#define PPP_READY BIT0
#define AP_READY BIT1
#define AP_IP "192.168.4.1"
#define PPP_ESP "192.168.11.1"
#define PPP_LINUX "192.168.11.2"
static const char *TAG="anlu_wifi";
static EventGroupHandle_t events;

static void ip_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    if (base==WIFI_EVENT && id==WIFI_EVENT_AP_START) xEventGroupSetBits(events, AP_READY);
    if (base==WIFI_EVENT && id==WIFI_EVENT_AP_STOP) xEventGroupClearBits(events, AP_READY);
    if (base==IP_EVENT && id==IP_EVENT_PPP_GOT_IP) {
        xEventGroupSetBits(events, PPP_READY);
        ESP_LOGI(TAG, "PPP_UP ESP=" PPP_ESP " Linux=" PPP_LINUX);
    }
    if (base==IP_EVENT && id==IP_EVENT_PPP_LOST_IP) {
        xEventGroupClearBits(events, PPP_READY);
        ESP_LOGW(TAG, "PPP_DOWN; SSH forwarding unavailable until renegotiation");
    }
}

static int listening(const char *address, int port)
{
    int fd=socket(AF_INET, SOCK_STREAM, IPPROTO_TCP), yes=1;
    struct sockaddr_in local={.sin_family=AF_INET, .sin_port=htons(port)};
    local.sin_addr.s_addr=inet_addr(address);
    if (fd<0) return -1;
    setsockopt(fd,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof(yes));
    if (bind(fd,(struct sockaddr *)&local,sizeof(local)) || listen(fd,1)) {
        close(fd); return -1;
    }
    return fd;
}

static void ssh_forward(void *arg)
{
    xEventGroupWaitBits(events,AP_READY,pdFALSE,pdTRUE,portMAX_DELAY);
    int listener=listening(AP_IP,2222);
    if (listener<0) { ESP_LOGE(TAG,"SSH listener failed"); vTaskDelete(NULL); return; }
    ESP_LOGI(TAG,"SSH_FORWARD_V2 " AP_IP ":2222 -> " PPP_LINUX ":2222 (one session, bounded connect)");
    for (;;) {
        int client=accept(listener,NULL,NULL);
        if (client<0) { vTaskDelay(pdMS_TO_TICKS(200)); continue; }
        ESP_LOGI(TAG,"SSH_ACCEPT client=%d",client);
        if (!(xEventGroupGetBits(events)&PPP_READY)) {
            ESP_LOGW(TAG,"SSH_DROP PPP not ready"); close(client); continue;
        }
        if (relay_keepalive(client)) {
            ESP_LOGW(TAG,"SSH client keepalive failed errno=%d",errno);
            close(client); continue;
        }
        int backend=socket(AF_INET,SOCK_STREAM,IPPROTO_TCP);
        ESP_LOGI(TAG,"SSH_BACKEND_CONNECT " PPP_LINUX ":2222 timeout_ms=15000");
        if (backend>=0 && !relay_keepalive(backend) && !relay_connect(backend,PPP_LINUX,2222,15000)) {
            ESP_LOGI(TAG,"SSH relay connected to Linux");
            int result=relay_stream(client,backend);
            ESP_LOGI(TAG,"SSH relay ended rc=%d errno=%d",result,result==-1 ? errno : 0);
        } else ESP_LOGW(TAG,"Linux SSH unavailable errno=%d",errno);
        if (backend>=0) close(backend);
        close(client);
    }
}

static void entropy_service(void *arg)
{
    xEventGroupWaitBits(events,PPP_READY|AP_READY,pdFALSE,pdTRUE,portMAX_DELAY);
    int listener=listening(PPP_ESP,6060);
    if (listener<0) { ESP_LOGE(TAG,"Entropy listener failed"); vTaskDelete(NULL); return; }
    for (;;) {
        struct sockaddr_in peer; socklen_t size=sizeof(peer);
        int client=accept(listener,(struct sockaddr *)&peer,&size);
        if (client<0) { vTaskDelay(pdMS_TO_TICKS(200)); continue; }
        /* The physical UART peer is trusted. Never expose entropy bytes in logs. */
        if (peer.sin_addr.s_addr==inet_addr(PPP_LINUX) && (xEventGroupGetBits(events)&AP_READY)) {
            unsigned char seed[32]; size_t offset=0;
            struct timeval timeout={.tv_sec=5};
            setsockopt(client,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
            /* esp_fill_random has true entropy while Wi-Fi is active. */
            esp_fill_random(seed,sizeof(seed));
            while (offset<sizeof(seed)) {
                int n=send(client,seed+offset,sizeof(seed)-offset,0);
                if (n<=0) break;
                offset+=(size_t)n;
            }
            memset(seed,0,sizeof(seed));
        }
        close(client);
    }
}

static void ppp_server(void *arg)
{
    eppp_config_t cfg=EPPP_DEFAULT_SERVER_CONFIG();
    cfg.transport=EPPP_TRANSPORT_UART;
    cfg.uart.port=1;
    cfg.uart.tx_io=4;
    cfg.uart.rx_io=5;
    cfg.uart.baud=115200;
    cfg.uart.rx_buffer_size=4096;
    cfg.uart.rts_io=-1;
    cfg.uart.cts_io=-1;
    cfg.uart.flow_control=0;
    ESP_LOGI(TAG,"PPP UART1 TX=IO4 RX=IO5, 115200 8N1; USB UART0 separate");
    if (!eppp_listen(&cfg)) ESP_LOGE(TAG,"PPP server startup failed");
    vTaskDelete(NULL);
}

void app_main(void)
{
    ESP_ERROR_CHECK(nvs_flash_init());
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    events=xEventGroupCreate();
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT,ESP_EVENT_ANY_ID,ip_event,NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT,ESP_EVENT_ANY_ID,ip_event,NULL));
    esp_netif_t *ap=esp_netif_create_default_wifi_ap();
    esp_netif_ip_info_t ip={0};
    ip.ip.addr=inet_addr(AP_IP); ip.gw=ip.ip; ip.netmask.addr=inet_addr("255.255.255.0");
    ESP_ERROR_CHECK(esp_netif_dhcps_stop(ap));
    ESP_ERROR_CHECK(esp_netif_set_ip_info(ap,&ip));
    ESP_ERROR_CHECK(esp_netif_dhcps_start(ap));
    wifi_init_config_t init=WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&init));
    wifi_config_t config={.ap={.ssid=ANLU_WIFI_SSID,.password=ANLU_WIFI_PASSWORD,
        .ssid_len=sizeof(ANLU_WIFI_SSID)-1,.channel=6,.max_connection=2,
        .authmode=WIFI_AUTH_WPA2_PSK,.pmf_cfg={.capable=true,.required=false}}};
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_AP));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_AP,&config));
    ESP_ERROR_CHECK(esp_wifi_start());
    ESP_LOGI(TAG,"AP ready: %s; password is in local wifi_credentials.h",ANLU_WIFI_SSID);
    configASSERT(xTaskCreate(ppp_server,"ppp_server",4096,NULL,5,NULL)==pdPASS);
    configASSERT(xTaskCreate(ssh_forward,"ssh_relay",6144,NULL,4,NULL)==pdPASS);
    configASSERT(xTaskCreate(entropy_service,"entropy",3072,NULL,4,NULL)==pdPASS);
}
