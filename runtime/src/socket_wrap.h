/* socket 包装头（zI 侧 @cInclude） */
#ifndef DSH_SOCKET_WRAP_H
#define DSH_SOCKET_WRAP_H
#include <stddef.h>
#include <stdint.h>
int dsh_sock_listen(uint16_t port);
int dsh_sock_connect(uint16_t port);
int dsh_sock_accept(int s);
int dsh_sock_set_nonblock(int s);
int dsh_sock_port(int s);
long dsh_sock_write(int fd, const void *buf, size_t len);
long dsh_sock_read(int fd, void *buf, size_t len);
int dsh_sock_close(int fd);
#endif
