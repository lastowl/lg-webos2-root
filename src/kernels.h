#ifndef KERNELS_H
#define KERNELS_H

struct kernel_info {
    const char *version;
    unsigned long modprobe_path;
    int mem_split; /* 2 = 2G/2G (kernel at 0x80000000), 3 = 3G/1G (kernel at 0xC0000000) */
};

static const struct kernel_info known_kernels[] = {
    /* webOS 2.2.3 - UF850V, MStar SoC */
    { "3.10.23-p.21.biscayne.lm15u.11", 0x8082de00, 2 },
    /* Add new entries here as they are discovered.
     * To find values for your TV:
     *   uname -r                           -> version string
     *   grep modprobe_path /proc/kallsyms  -> modprobe_path address
     *   If kernel base is 0x80008000 -> mem_split = 2
     *   If kernel base is 0xC0008000 -> mem_split = 3
     */
    { NULL, 0, 0 }
};

#endif
