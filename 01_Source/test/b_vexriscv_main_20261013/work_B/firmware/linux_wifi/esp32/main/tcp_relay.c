// SPDX-License-Identifier: MIT
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#ifdef ESP_PLATFORM
#include "lwip/sockets.h"
#else
#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <unistd.h>
#endif
#include "tcp_relay.h"

int relay_connect(int fd, const char *address, unsigned short port, int timeout_ms)
{
    struct sockaddr_in remote = {.sin_family=AF_INET, .sin_port=htons(port)};
    fd_set writes, errors;
    struct timeval timeout = {.tv_sec=timeout_ms/1000, .tv_usec=(timeout_ms%1000)*1000};
    int result, error = 0;
    socklen_t length = sizeof(error);
    if (timeout_ms <= 0 || inet_pton(AF_INET, address, &remote.sin_addr) != 1) {
        errno = EINVAL;
        return -1;
    }
    if (fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) < 0) return -1;
    if (!connect(fd, (struct sockaddr *)&remote, sizeof(remote))) return 0;
    if (errno != EINPROGRESS && errno != EWOULDBLOCK) return -1;
    FD_ZERO(&writes); FD_ZERO(&errors);
    FD_SET(fd, &writes); FD_SET(fd, &errors);
    result = select(fd+1, NULL, &writes, &errors, &timeout);
    if (result < 0) return -1;
    if (!result) { errno = ETIMEDOUT; return -1; }
    /* A refused connection is writable too: SO_ERROR decides success. */
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)) return -1;
    if (error) { errno = error; return -1; }
    return 0;
}

int relay_keepalive(int fd)
{
    int enabled = 1, idle = 30, interval = 10, probes = 3;
    if (setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &enabled, sizeof(enabled)) ||
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &idle, sizeof(idle)) ||
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &interval, sizeof(interval)) ||
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &probes, sizeof(probes))) return -1;
    return 0;
}

struct flow {
    int source, target, eof, shutdown;
    unsigned char data[1024];
    size_t length;
};

int relay_stream(int left, int right)
{
    struct flow f[2] = {{.source=left, .target=right}, {.source=right, .target=left}};
    int idle = 0, top = left > right ? left : right;
    if (fcntl(left, F_SETFL, fcntl(left, F_GETFL) | O_NONBLOCK) < 0 ||
        fcntl(right, F_SETFL, fcntl(right, F_GETFL) | O_NONBLOCK) < 0)
        return -1;
    for (;;) {
        fd_set reads, writes;
        struct timeval timeout = {.tv_sec=1};
        int done = 0;
        FD_ZERO(&reads); FD_ZERO(&writes);
        for (int i=0; i<2; i++) {
            if (!f[i].eof && f[i].length < sizeof(f[i].data)) FD_SET(f[i].source, &reads);
            if (f[i].length) FD_SET(f[i].target, &writes);
            if (f[i].eof && !f[i].length) {
                if (!f[i].shutdown) { shutdown(f[i].target, SHUT_WR); f[i].shutdown=1; }
                done++;
            }
        }
        if (done==2) return 0;
        int n=select(top+1, &reads, &writes, NULL, &timeout);
        if (n<0) { if (errno==EINTR) continue; return -1; }
        if (!n) { if (++idle>=900) return -2; continue; }
        idle=0;
        for (int i=0; i<2; i++) {
            if (FD_ISSET(f[i].target, &writes)) {
                ssize_t sent=send(f[i].target, f[i].data, f[i].length, 0);
                if (sent>0) {
                    f[i].length-=(size_t)sent;
                    memmove(f[i].data, f[i].data+sent, f[i].length);
                } else if (sent==0 || (errno!=EAGAIN && errno!=EWOULDBLOCK && errno!=EINTR)) return -1;
            }
            if (FD_ISSET(f[i].source, &reads)) {
                ssize_t got=recv(f[i].source, f[i].data+f[i].length,
                                 sizeof(f[i].data)-f[i].length, 0);
                if (got>0) f[i].length+=(size_t)got;
                else if (!got) f[i].eof=1;
                else if (errno!=EAGAIN && errno!=EWOULDBLOCK && errno!=EINTR) return -1;
            }
        }
    }
}
