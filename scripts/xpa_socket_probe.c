// Connect to a Unix socket, returning 0 on success and 1 on refusal.
// Used by test_xpa_local_security.sh under two distinct Linux UIDs.
#include <stddef.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 2 || strlen(argv[1]) >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
        return 2;
    }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return 2;
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strcpy(address.sun_path, argv[1]);
    socklen_t length = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + strlen(argv[1]) + 1);
    int result = connect(fd, (struct sockaddr *)&address, length);
    close(fd);
    return result == 0 ? 0 : 1;
}
