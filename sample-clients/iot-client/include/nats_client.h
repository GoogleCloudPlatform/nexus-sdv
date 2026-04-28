#ifndef NATS_CLIENT_H
#define NATS_CLIENT_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

// Minimal NATS client supporting CONNECT (with JWT auth) and PUB.
// Implements PING/PONG keepalive.

typedef struct NatsClient NatsClient;

NatsClient *nats_create();
bool nats_connect(NatsClient *nc, const char *url, const char *token);
bool nats_publish(NatsClient *nc, const char *subject, const uint8_t *data, size_t len);
bool nats_process(NatsClient *nc);
bool nats_is_connected(NatsClient *nc);
void nats_disconnect(NatsClient *nc);
void nats_destroy(NatsClient *nc);

#endif
