#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv) {
    sigset_t signals;

    if (argc < 2) {
        fprintf(stderr, "usage: block-winch command [args...]\n");
        return 2;
    }
    if (sigemptyset(&signals) != 0 ||
        sigaddset(&signals, SIGWINCH) != 0 ||
        sigprocmask(SIG_BLOCK, &signals, NULL) != 0) {
        perror("blocking SIGWINCH");
        return 1;
    }
    execvp(argv[1], &argv[1]);
    perror(argv[1]);
    return errno == ENOENT ? 127 : 126;
}
