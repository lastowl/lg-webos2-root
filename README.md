# lg-webos-root

Persistent root for LG webOS TVs with vulnerable kernels (CVE-2014-3153).

Targets ARM 32-bit webOS builds running kernel 3.10.x before the futex requeue bug was patched. Tested on webOS 2.x; may work on 1.x and early 3.x with matching kernels.

## How it works

1. **Exploit** — Uses the futex requeue bug (CVE-2014-3153, aka towelroot) to expand the current thread's `addr_limit`, then overwrites `modprobe_path` via pipe read/write to point at a helper script. Triggering modprobe on an unknown binary format runs the script as root, which sets up a SUID root shell at `/tmp/rootsh`.

2. **Persistence (at boot, recommended)** — `scripts/boot-persist.sh` hooks the top of `start-devmode.sh`, which upstart runs **as root** on every boot while dev mode is on (job fires on `minimal-boot-done`), so the exploit is not needed at boot at all. It also makes the dev-mode flag permanent and serves a root sshd on port 22. Replaces the earlier `autoroot-boot.sh` scheme, which raced the exploit against boot and often missed. See [Root at boot without the exploit](#root-at-boot-without-the-exploit).

3. **Persistence (on-demand fallback)** — Patches `authorized_keys` with a `command=` directive that runs a wrapper script on every prisoner SSH connection. The wrapper launches the exploit in the background if root isn't already active, then transparently passes through to the original command. `authorized_keys` survives reboots because the boot script (`start-devmode.sh`) only creates it when it doesn't exist.

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

## Root at boot without the exploit

Upstart's `/etc/init/devmode.conf` runs the dev-mode service's
`start-devmode.sh` **as root** on every boot while developer mode is
enabled. `scripts/boot-persist.sh` installs itself as a hook at the top of
that script and from the first second of boot it:

- makes the dev-mode flag **permanent** — `devmode_enabled` becomes a
  directory (existence checks still pass, LG's expiry logic only ever `rm`s
  a file), with the real session token preserved in
  `/media/developer/persist/devmode_token` and `start-devmode.sh` patched
  to read it, so LG's own session check keeps succeeding and
  `/media/developer` never gets wiped
- starts a **root sshd on port 22** with pubkey auth — host identity in
  `persist/ssh_host_rsa_key`, authorized keys served from
  `persist/root_authorized_keys`
- runs your own `persist/boot-payload.sh` if present
- re-installs its hook every boot (the Dev Mode app re-extracts pristine
  service files shortly after running them) and is flock-guarded once per
  boot

The towelroot wrapper on `prisoner@:9922` stays as the fallback path.

### Install

```bash
TV=192.168.1.100
cat scripts/boot-persist.sh | ssh -p 9922 prisoner@$TV \
    'cat > /media/developer/persist/boot-persist.sh'
ssh -p 9922 prisoner@$TV '/tmp/rootsh -c "
    chmod 755 /media/developer/persist/boot-persist.sh
    /media/developer/persist/boot-persist.sh"'
```

(seed `persist/root_authorized_keys` with your public key — the script also
copies it from `/home/root/.ssh/authorized_keys` whenever it can see it)

Then `ssh -p 22 root@$TV` works within 1-3 minutes of every power-on, no
exploit run, no intervention. It also survives the failure modes that make
the naive approaches flaky — the comments in the script are a changelog of
what each clause defends against (jail chroot with empty `/home`, mid-boot
`/media/developer` and cryptofs remounts, daemons born too early that stop
answering connections, `$(...)` substitution deadlocks at boot+3s).

### Bonus: waking the TV over the network

With Settings -> Network -> *Mobile TV On*, the NIC stays live in standby
and answers a Wake-on-LAN magic packet on UDP 9/7:

```bash
python3 - "$TV" <<'PY'
import socket, binascii, subprocess, sys
arp = subprocess.run(["arp", "-n", sys.argv[1]], capture_output=True, text=True).stdout
mac = [w for w in arp.split() if ":" in w and w.count(":") == 5][0]
pkt = b"\xff" * 6 + binascii.unhexlify(mac.replace(":", "")) * 16
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
for p in (9, 7): s.sendto(pkt, ("192.168.1.255", p))
PY
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
├── boot-persist.sh    # Boot chain: hook + flag persistence + root sshd (see above)
├── root_authorized_keys  # Keys served by the :22 sshd (AuthorizedKeysFile)
├── devmode_token      # Preserved dev-mode session token
├── ssh_host_rsa_key   # Persistent SSH host key (0600 copy lives on /tmp at boot)
├── boot-payload.sh    # Optional: your own start-at-boot program
├── towelroot          # The exploit binary (on-demand fallback)
├── rootsh             # SUID root shell (copied to /tmp when exploit runs)
├── dotrigger          # modprobe trigger helper
├── ssh_wrapper.sh     # authorized_keys command wrapper (SSH fallback)
├── autoroot-boot.sh   # Legacy boot scheme (superseded by boot-persist.sh)
└── boot-root.sh       # Legacy boot scheme (superseded by boot-persist.sh)

/media/cryptofs/apps/usr/palm/services/com.palmdts.devmode.service/
└── start-devmode.sh   # Patched with the early hook; token check repointed

/media/developer/.ssh/
└── authorized_keys    # Patched with command= for the wrapper fallback

/var/luna/preferences/devmode_enabled   # Now a DIRECTORY (survives expiry;
                                        # holds the real token)
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

The `appinstalld` daemon *can* re-extract `start-devmode.sh` from the devmode service IPK (e.g. after a firmware update or app reinstall), which would remove our patch. `boot-persist.sh` handles this by re-applying the hook a few minutes after every boot (and at the start of each boot), so one successful boot repairs the next. Note the Dev Mode app re-extracts the service files AFTER running them, so the hook that ran this boot may be gone until the late re-patch lands — patching early in the boot script itself is what closes that window.

The `authorized_keys` file also persists — it is only created when it doesn't exist (`if [ ! -e ... ]` guard in `start-devmode.sh`). The wrapper hook there serves as a fallback if the boot-time autoroot didn't fire.

`/tmp` is tmpfs and cleared on every reboot, so the SUID rootsh and the `/tmp/rooted` flag must be re-created each boot by the exploit.

### CVE-2014-3153

The futex requeue bug allows a user-space thread to corrupt kernel memory through a race condition in `futex_requeue()`. The dangling waiter's `prio_list` pointers are sprayed via `sendmmsg` to first leak a kernel stack address, then redirect a write to the thread's `addr_limit` field, expanding it to allow user-space access to kernel memory. With full kernel read/write, `modprobe_path` is overwritten to point at a root helper script.

## License

MIT
