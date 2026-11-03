idf_component_register(SRCS "main.c" "../../uart_timing.c" "${CMAKE_CURRENT_LIST_DIR}/../../../esp32/main/tcp_relay.c"
INCLUDE_DIRS "." "${CMAKE_CURRENT_LIST_DIR}/../../../esp32/main" REQUIRES eppp_link esp_wifi esp_event esp_netif nvs_flash esp_driver_rmt esp_driver_gpio esp_driver_uart)
