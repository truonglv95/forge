// Simple TCP server helper for forge serve command.
// Zig 0.16 removed std.posix.socket, so we use raw C syscalls.

#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <string.h>

int forge_create_server(int port) {
    int sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sockfd < 0) return -1;

    int optval = 1;
    setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &optval, sizeof(optval));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);

    if (bind(sockfd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        close(sockfd);
        return -2;
    }

    if (listen(sockfd, 8) < 0) {
        close(sockfd);
        return -3;
    }

    return sockfd;
}

int forge_accept_client(int sockfd) {
    struct sockaddr_in client_addr;
    socklen_t client_len = sizeof(client_addr);
    return accept(sockfd, (struct sockaddr*)&client_addr, &client_len);
}

int forge_read_client(int fd, char *buf, int len) {
    return read(fd, buf, len);
}

int forge_write_client(int fd, const char *buf, int len) {
    return write(fd, buf, len);
}

void forge_close_fd(int fd) {
    close(fd);
}
