#ifndef WIFI_MANAGER_H
#define WIFI_MANAGER_H

#include <stdbool.h>

bool wifi_init(const char *ssid, const char *password);
bool wifi_is_connected();
void wifi_wait_for_connection(unsigned long timeout_ms);
void wifi_disconnect();

#endif
