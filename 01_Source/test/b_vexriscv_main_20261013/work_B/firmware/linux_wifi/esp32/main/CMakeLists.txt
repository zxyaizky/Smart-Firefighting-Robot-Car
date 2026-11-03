idf_component_register(SRCS "main.c" "tcp_relay.c"
    INCLUDE_DIRS "." REQUIRES eppp_link esp_wifi esp_event esp_netif nvs_flash)
