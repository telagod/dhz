/* socket 薄包装（C）——HTTP 服务 transport 层。
 * 绕开 std.Io.Threaded 的异步调度依赖（见 design-runtime-core §7：netWritePosix
 * 经 Syscall.start() 入队，需调度器驱动）。阻塞式 POSIX 语义，smoke/服务端共用。 */
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

int dsh_sock_listen(uint16_t port) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return -1;
    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(s, (struct sockaddr *)&a, sizeof a) < 0) { close(s); return -1; }
    if (listen(s, 128) < 0) { close(s); return -1; }
    return s;
}

int dsh_sock_connect(uint16_t port) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return -1;
    /* 分段小写（头部+body）不被 Nagle 扣住等对端延迟 ACK（实测 40ms 级互等摆动） */
    int nd = 1;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &nd, sizeof nd);
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(s, (struct sockaddr *)&a, sizeof a) < 0) { close(s); return -1; }
    return s;
}

int dsh_sock_accept(int s) {
    return accept(s, NULL, NULL);
}

/* 事件循环集成：listen fd 需要非阻塞 accept（LT 模式下无连接时 accept 会阻塞
 * 事件循环！）。连接 fd 本身仍阻塞读（v1 每请求一连接，客户端帧完整）。 */
#include <fcntl.h>
int dsh_sock_set_nonblock(int s) {
    int flags = fcntl(s, F_GETFL, 0);
    if (flags < 0) return -1;
    return fcntl(s, F_SETFL, flags | O_NONBLOCK);
}

int dsh_sock_port(int s) {
    struct sockaddr_in a;
    socklen_t l = sizeof a;
    if (getsockname(s, (struct sockaddr *)&a, &l) < 0) return -1;
    return ntohs(a.sin_port);
}

ssize_t dsh_sock_write(int fd, const void *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, (const char *)buf + off, len - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        off += (size_t)n;
    }
    return (ssize_t)off;
}

ssize_t dsh_sock_read(int fd, void *buf, size_t len) {
    return read(fd, buf, len);
}

int dsh_sock_close(int fd) {
    return close(fd);
}
