# lg-webos-root

Persistent root for LG webOS TVs with vulnerable kernels (CVE-2014-3153).

Targets ARM 32-bit webOS builds running kernel 3.10.x before the futex requeue bug was patched. Tested on webOS 2.x; may work on 1.x and early 3.x with matching kernels.

## How it works

1. **Exploit** — Uses the futex requeue bug (CVE-2014-3153, aka towelroot) to expand the current thread's `addr_limit`, then overwrites `modprobe_path` via pipe read/write to point at a helper script. Triggering modprobe on an unknown binary format runs the script as root, which sets up a SUID root shell at `/tmp/rootsh`.

2. **Boot persistence** — Patches `start-devmode.sh` (the devmode service startup script on the writable `/media` partition) to launch `autoroot-boot.sh` early in the boot process. The devmode upstart job fires on `minimal-boot-done`, which runs before `appinstalld` starts. The autoroot script runs the exploit, starts root sshd and RPiPlay, then monitors `start-devmode.sh` in the background — if `appinstalld` ever re-extracts the original (e.g. after a firmware update), the patch is re-applied automatically for the next boot. Root SSH is typically available 30-60 seconds after power-on.

3. **SSH fallback** — Patches `authorized_keys` with a `command=` directive that runs a wrapper script on every prisoner SSH connection. If root isn't active yet, the wrapper launches the exploit in the background and also starts the root sshd once it succeeds. `authorized_keys` survives reboots because `start-devmode.sh` only creates it when it doesn't exist.

4. **Address resolution** — Reads `/proc/kallsyms` at runtime to find `modprobe_path` (works when `kptr_restrict=0`, which is common on webOS). Falls back to a built-in table of known kernel versions.

## Quick start

### Prerequisites

- LG webOS TV with Developer Mode enabled
- SSH access to the TV (`prisoner@<tv-ip> -p 9922`)
- Docker (for cross-compilation) or `arm-linux-gnueabi-gcc`

### Build

```bash
# With Docker (recommended):
make docker-build

# Or with a cross-compiler installed:
CC=arm-linux-gnueabi-gcc make
```

Binaries are output to `build/`.

### Deploy

```bash
./scripts/deploy.sh 192.168.1.100                # uses default SSH settings
./scripts/deploy.sh 192.168.1.100 ~/.ssh/tv_key   # with a specific key
```

The deploy script:
1. Uploads binaries to `/media/developer/persist/`
2. Runs the exploit to get initial root
3. Installs the persistence hook in `start-devmode.sh` and `authorized_keys`

### After reboot

Root activates automatically at boot. A root SSH server starts on port 22 within ~30-60 seconds:

```bash
ssh -p 22 root@<tv-ip> 'id'
# uid=0(root) gid=0(root) ...
```

If port 22 isn't up yet, SSH in as prisoner — the wrapper triggers root and starts sshd:

```bash
ssh -p 9922 prisoner@<tv-ip> '/tmp/rootsh -c "id"'
# uid=0(root) gid=0(root) ...
```

## Supported TVs

| Model | webOS | Kernel | Status |
|-------|-------|--------|--------|
| 49UF850V | 2.2.3 | 3.10.23-p.21.biscayne.lm15u.11 | Tested, working |

### Adding support for your TV

SSH into your TV and run:

```bash
uname -r
grep modprobe_path /proc/kallsyms
head -1 /proc/kallsyms
```

If `modprobe_path` shows a non-zero address, the exploit should work — the dynamic resolver handles it automatically.

If kallsyms is zeroed (`kptr_restrict=1`), add your kernel to `src/kernels.h`:

```c
{ "your-kernel-version-string", 0xYOUR_MODPROBE_ADDR, 2 },
```

The third field is the memory split: `2` if the kernel base (`stext`) is near `0x80008000` (2G/2G), `3` if near `0xC0008000` (3G/1G).

## Files on the TV

```
/media/developer/persist/
├── towelroot          # The exploit binary
├── rootsh             # SUID root shell (copied to /tmp at boot)
├── dotrigger          # modprobe trigger helper
├── autoroot-boot.sh   # Boot-time autoroot: exploit + sshd + start-devmode.sh re-patch
├── boot-root.sh       # Starts root sshd on port 22 and RPiPlay after exploit
├── ssh_wrapper.sh     # authorized_keys command wrapper (SSH fallback)
└── ssh_host_rsa_key   # Persistent SSH host key for root sshd

/media/cryptofs/apps/usr/palm/services/com.palmdts.devmode.service/
└── start-devmode.sh   # Patched with early hook to launch autoroot

/media/developer/.ssh/
└── authorized_keys    # Patched with command= for persistence

/home/root/.ssh/
└── authorized_keys    # Same public key, for root SSH on port 22
```

## Uninstalling

To remove root persistence:

```bash
# From the TV (with root):
/tmp/rootsh -c "cp /media/developer/.ssh/authorized_keys.bak /media/developer/.ssh/authorized_keys"

# Restore original start-devmode.sh:
/tmp/rootsh -c "cp /media/cryptofs/apps/usr/palm/services/com.palmdts.devmode.service/start-devmode.sh.orig /media/cryptofs/apps/usr/palm/services/com.palmdts.devmode.service/start-devmode.sh"

# Or delete authorized_keys entirely (it regenerates on next reboot):
/tmp/rootsh -c "rm /media/developer/.ssh/authorized_keys"
```

## Technical details

### Why this persistence method?

On webOS 2.x, the root filesystem is a read-only squashfs image — there is no writable overlay. Writable storage is limited to `/var` (mmcblk0p46), `/home` (mmcblk0p46), and `/media` (mmcblk0p47), which are separate ext4 partitions bind-mounted over the squashfs root.

The devmode upstart job (`devmode.conf`) fires on `minimal-boot-done` and runs `start-devmode.sh`, which lives on the writable `/media` partition at `/media/cryptofs/apps/usr/palm/services/com.palmdts.devmode.service/`. This script runs early in the boot sequence — before `appinstalld` starts (which fires on the later `rest-boot-done` event). Patching `start-devmode.sh` with a hook near the top gives us code execution as root during boot.

The `appinstalld` daemon *can* re-extract `start-devmode.sh` from the devmode service IPK (e.g. after a firmware update or app reinstall), which would remove our patch. To handle this, `autoroot-boot.sh` spawns a background watcher that monitors `start-devmode.sh` for 10 minutes after boot — if the hook marker disappears (indicating re-extraction), the watcher re-applies the patch automatically.

The `authorized_keys` file also persists — it is only created when it doesn't exist (`if [ ! -e ... ]` guard in `start-devmode.sh`). The wrapper hook there serves as a fallback if the boot-time autoroot didn't fire.

`/tmp` is tmpfs and cleared on every reboot, so the SUID rootsh and the `/tmp/rooted` flag must be re-created each boot by the exploit.

### CVE-2014-3153

The futex requeue bug allows a user-space thread to corrupt kernel memory through a race condition in `futex_requeue()`. The dangling waiter's `prio_list` pointers are sprayed via `sendmmsg` to first leak a kernel stack address, then redirect a write to the thread's `addr_limit` field, expanding it to allow user-space access to kernel memory. With full kernel read/write, `modprobe_path` is overwritten to point at a root helper script.

## License

MIT
