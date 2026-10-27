/* Execute /tmp/trigger to invoke modprobe on the unknown binary format.
 * BusyBox exec can return ENOEXEC on raw binaries; this helper avoids that. */
#include <unistd.h>
int main(void) {
    execl("/tmp/trigger", "/tmp/trigger", NULL);
    return 1;
}
