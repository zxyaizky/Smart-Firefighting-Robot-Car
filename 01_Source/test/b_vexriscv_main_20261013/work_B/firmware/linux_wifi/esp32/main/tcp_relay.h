#pragma once
/* Blocking lifetime, bounded buffers, nonblocking sockets and TCP half-close. */
int relay_stream(int left, int right);
/* Leave the connected socket nonblocking, ready for relay_stream. */
int relay_connect(int fd, const char *address, unsigned short port, int timeout_ms);
int relay_keepalive(int fd);
