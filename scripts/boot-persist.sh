#!/bin/sh
# Root-at-boot for LG webOS 2.x WITHOUT running the exploit at boot.
#
# Upstart (/etc/init/devmode.conf) runs the dev-mode service's
# start-devmode.sh AS ROOT on every boot while developer mode is enabled -
# so a hook at the top of that script is root from the very first second.
# The towelroot exploit stays only as the on-demand fallback for prisoner
# shells (the ssh_wrapper command= hook); nothing needs it at boot anymore.
#
# This is the generalised, battle-tested form of the chain developed on a
# 49UF850V / webOS 2.2.3 (dozens of cold boots), where it survived every
# reset LG throws at the boot files. What it does, in order:
#
#   1. escapes the dev-mode jail (the hook runs chrooted)
#   2. makes the devmode flag permanent: devmode_enabled is a session-token
#      FILE that LG deletes when the session expires, after which
#      devmode.conf rm -rf's ALL of /media/developer. A DIRECTORY passes
#      every existence check (mvpd-autoroot trick); the real token is kept
#      in persist/devmode_token and start-devmode.sh is patched to read it,
#      so LG's session check keeps passing (open the Dev Mode app once in a
#      while and it renews the token as usual).
#   3. starts a root sshd on port 22 with pubkey auth (host identity in
#      persist/ssh_host_rsa_key, keys from persist/root_authorized_keys)
#   4. re-patches itself after the Dev Mode app re-extracts pristine
#      service files shortly after running them each boot
#   5. runs /media/developer/persist/boot-payload.sh if present - your own
#      start-at-boot program goes there
#
# Once per boot (flock), self-healing, safe to run by hand at any time.
#
# Install once (as root, e.g. via the towelroot wrapper):
#   cat boot-persist.sh | ssh -p 9922 prisoner@TV \
#       'cat > /media/developer/persist/boot-persist.sh'
#   ssh -p 9922 prisoner@TV \
#       '/tmp/rootsh -c "chmod 755 /media/developer/persist/boot-persist.sh;
#                         /media/developer/persist/boot-persist.sh"'
# From the next boot on, ssh root@TV -p 22 works within 1-3 minutes of
# power-on with no intervention.

# No apostrophes anywhere - the file is pushed through ssh heredocs.

# --- run in the real root filesystem ------------------------------------------
# The start-devmode.sh hook executes inside the dev-mode jail (chroot). Do
# NOT detect it with readlink /proc/self/root: procfs renders that link
# relative to the reader, so it shows / even inside the chroot. Use the
# test -ef builtin (device + inode compare). Never put a $(...) substitution
# this early: ash blocks on the substitution pipe forever if any forked
# child keeps its write end open (real deadlock seen at boot+3s).
if [ -d /proc/1/root ] && ! [ / -ef /proc/1/root ]; then
    exec /proc/1/root/bin/busybox chroot /proc/1/root /bin/sh "$0" "$@"
fi

PERSIST=/media/developer/persist
START_DEVMODE=/media/cryptofs/apps/usr/palm/services/com.palmdts.devmode.service/start-devmode.sh
PREFS=/var/luna/preferences
TOKEN_FILE=$PREFS/devmode_enabled/token
LOGF=/tmp/boot-persist.log

log() {
    echo "$(date) boot-persist: $*" >> "$LOGF"
}

# Exact port-22 listener check ("grep :22" also matches :9922).
port22_up() {
    netstat -tln 2>/dev/null | awk '{print $4}' | grep -Eq '[:.]22$'
}

# --- once per boot, and never twice at once ----------------------------------
once=/tmp/boot_persist
exec 200>${once}.lock
if ! flock -x -n 200; then
    log "already running, exiting"
    exit 1
fi
trap "rm -f ${once}.lock" EXIT
[ -f "$once" ] && { log "already finished, exiting"; exit 2; }
touch "$once"
log "begin (uid=$(id -u))"

# --- permanent devmode flag ----------------------------------------------------
if [ ! -d "$PREFS/devmode_enabled" ]; then
    # preserve a live token before converting file -> directory
    if [ -f "$PREFS/devmode_enabled" ]; then
        tok=$(cat "$PREFS/devmode_enabled" 2>/dev/null)
        rm -f "$PREFS/devmode_enabled"
        mkdir -p "$PREFS/devmode_enabled"
        [ -n "$tok" ] && printf '%s' "$tok" > "$TOKEN_FILE"
    else
        mkdir -p "$PREFS/devmode_enabled"
    fi
    log "devmode_enabled converted to persistent directory"
fi
[ -f "$TOKEN_FILE" ] || {
    tok=$(ls -t "$PREFS"/devmode_enabled/* 2>/dev/null | head -1)
    [ -n "$tok" ] && cp -f "$tok" "$TOKEN_FILE" 2>/dev/null
}
# If the dev-mode app ever re-created a token file beside an old directory
# (jailer resets), adopt it instead of letting LG see a stale one.
if [ -f "$PREFS/devmode_enabled" ] && [ -f "$TOKEN_FILE" ]; then
    printf '%s' "$(cat "$TOKEN_FILE")" > "$PREFS/devmode_enabled"
fi
rm -f "$PREFS"/dc* 2>/dev/null    # devmode reboot/session counters

# --- patch + self-heal start-devmode.sh ---------------------------------------
patch_start_devmode() {
    [ -f "$START_DEVMODE" ] || return 0
    if ! grep -q "BOOT-PERSIST HOOK" "$START_DEVMODE" 2>/dev/null; then
        # clear older generations of hooks from either project
        sed -i "/=== AUTOROOT BOOT HOOK ===/,/=== END AUTOROOT ===/d" \
            "$START_DEVMODE" 2>/dev/null
        sed -i "/=== RPIPLAY BOOT HOOK ===/,/=== END RPIPLAY HOOK ===/d" \
            "$START_DEVMODE" 2>/dev/null
        sed -i '1a\
# === BOOT-PERSIST HOOK ===\
LD_PRELOAD="" nohup /media/developer/persist/boot-persist.sh > /dev/null 2>\&1 < /dev/null \&\
# === END BOOT-PERSIST HOOK ===' "$START_DEVMODE" 2>/dev/null
        chmod 700 "$START_DEVMODE" 2>/dev/null
        log "boot hook injected into start-devmode.sh"
    fi
    # point the session check at the preserved token, so an expired session
    # can never rm -rf the flag directory (open the Dev Mode app now and
    # then to renew the token; then update persist/devmode_token)
    grep -q "cat /var/luna/preferences/devmode_enabled);" "$START_DEVMODE" 2>/dev/null && \
    ! grep -q "persist/devmode_token" "$START_DEVMODE" 2>/dev/null && {
        mkdir -p "$PERSIST"
        cp -f "$TOKEN_FILE" "$PERSIST/devmode_token" 2>/dev/null
        sed -i "s|cat /var/luna/preferences/devmode_enabled);|cat /media/developer/persist/devmode_token);|" \
            "$START_DEVMODE" 2>/dev/null
        log "session check pointed at persist/devmode_token"
    }
    return 0
}
patch_start_devmode

# --- root sshd on port 22 -------------------------------------------------------
# /opt/openssh only exists inside the dev-mode jail; in the real rootfs the
# sshd binary ships with the devmode service (cryptofs, mounted ro) and
# needs its bundled libs on LD_LIBRARY_PATH.
SSHD=""
for cand in /opt/openssh/sbin/sshd \
    /media/cryptofs/apps/usr/palm/services/com.palmdts.devmode.service/binaries-armv71/opt/openssh/sbin/sshd \
    /media/cryptofs/apps/usr/palm/services/com.palmdts.devmode.service/binaries-i686/opt/openssh/sbin/sshd
do
    [ -x "$cand" ] && { SSHD=$cand; break; }
done

# A sshd mmapped from cryptofs at boot crashes its per-connection children
# later ("undefined instruction" in dmesg): LG remounts cryptofs partitions
# while booting and the not-yet-faulted pages come back wrong. Copy the few
# megabytes of openssh to tmpfs (RAM, unmount-proof) when it came from there.
if [ -n "$SSHD" ] && [ "${SSHD#/media/cryptofs}" != "$SSHD" ]; then
    RUNDIR=/tmp/openssh-run
    if [ ! -x "$RUNDIR/sbin/sshd" ]; then
        mkdir -p "$RUNDIR"
        cp -a "${SSHD%/sbin/sshd}/." "$RUNDIR/" 2>/dev/null
    fi
    if [ -x "$RUNDIR/sbin/sshd" ]; then
        SSHD=$RUNDIR/sbin/sshd
        log "sshd copied to RAM ($RUNDIR)"
    fi
fi

# Host identity: generate once (ssh-keygen ships only inside the jail).
mkdir -p "$PERSIST"
if [ ! -s "$PERSIST/ssh_host_rsa_key" ]; then
    for kg in /opt/openssh/bin/ssh-keygen \
        /media/cryptofs/apps/usr/palm/services/com.palmdts.devmode.service/binaries-armv71/opt/openssh/bin/ssh-keygen
    do
        [ -x "$kg" ] && {
            LD_LIBRARY_PATH="${kg%/*}/../lib/openssh" \
                "$kg" -t rsa -N "" -f "$PERSIST/ssh_host_rsa_key" >/dev/null 2>&1
            break
        }
    done
    chmod 600 "$PERSIST/ssh_host_rsa_key" 2>/dev/null
    log "host key generated: $(cat "$PERSIST/ssh_host_rsa_key.pub" 2>/dev/null | cut -c1-40)..."
fi

start_sshd() {
    # /var/run is tmpfs-mounted around minimal-boot-done and can bury
    # a privsep dir created earlier; privsep is disabled (-o below) so the
    # children need none, and the mkdir stays as belt and braces for the
    # runtime-started case
    mkdir -p /var/run/sshd
    # Host key from tmpfs: /media/developer is remounted with a loosened
    # mode mask (~0775) while the Dev Mode app re-extracts mid-boot, and
    # sshd refuses "too open" host keys (exits: no hostkeys available).
    HK=/tmp/bootpersist_host_rsa_key
    cp "$PERSIST/ssh_host_rsa_key" "$HK" 2>/dev/null && chmod 600 "$HK"
    [ -s "$HK" ] || HK="$PERSIST/ssh_host_rsa_key"
    # Auth keys from persist, NOT /home/root/.ssh: inside the dev-mode jail
    # /home is empty, so a boot-born jailed daemon denies keys that an
    # identical runtime daemon happily accepts. /media/developer is
    # bind-mounted, so this file is the same bytes from every context.
    AKF="$PERSIST/root_authorized_keys"
    [ -s /home/root/.ssh/authorized_keys ] && cp /home/root/.ssh/authorized_keys "$AKF" 2>/dev/null
    AKOPT=""
    if [ -s "$AKF" ]; then
        chmod 644 "$AKF" 2>/dev/null
        AKOPT="-o AuthorizedKeysFile=$AKF"
    fi
    LD_LIBRARY_PATH="${SSHD%/*}/../lib/openssh${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        "$SSHD" \
        -f /dev/null \
        -o StrictModes=no \
        -o UsePrivilegeSeparation=no \
        -o PermitRootLogin=yes \
        -o PasswordAuthentication=no \
        -o PermitUserEnvironment=yes \
        -o UseDNS=no \
        $AKOPT \
        -h "$HK" \
        -p 22 2>> "$LOGF"
}

# Wait for a real network address (up to ~30s); skip if :22 is taken.
i=0
while [ $i -lt 30 ]; do
    port22_up && break
    n=$(ifconfig -a 2>/dev/null | grep "inet addr:" | grep -vc "addr:127\.\|addr:169\.254\.")
    [ "${n:-0}" -ge 1 ] && break
    sleep 1
    i=$((i + 1))
done
if ! port22_up; then
    if [ -n "$SSHD" ]; then
        mkdir -p /home/root/.ssh /var/run/sshd
        chmod 700 /home/root/.ssh 2>/dev/null
        chmod 600 "$PERSIST/ssh_host_rsa_key" 2>/dev/null
        attempt=0
        while [ $attempt -lt 3 ]; do
            attempt=$((attempt + 1))
            if start_sshd; then
                sleep 2
                if port22_up; then
                    log "root sshd listening on port 22 ($SSHD)"
                    break
                fi
                log "sshd exited 0 but is NOT listening (attempt $attempt)"
            else
                log "sshd FAILED to start, rc=$? (attempt $attempt)"
            fi
            sleep 10
        done
    else
        log "no sshd binary found - skipping"
    fi
else
    log "port 22 already in use, skipping sshd"
fi

# --- towelroot fallback for unrooted prisoner shells ----------------------------
# Keeps /tmp/rootsh ready for the ssh_wrapper hook; the autoroot script exits
# straight away when already rooted.
[ -x "$PERSIST/autoroot.sh" ] && "$PERSIST/autoroot.sh" >/dev/null 2>&1 &

# --- user payload -----------------------------------------------------------------
if [ -x "$PERSIST/boot-payload.sh" ]; then
    LD_PRELOAD="" nohup "$PERSIST/boot-payload.sh" >/dev/null 2>&1 </dev/null &
    log "payload launched"
fi

log "done"

# --- late maintenance -------------------------------------------------------------
# Two known late-boot effects, both seen on real boots:
#   1) the Dev Mode app re-extracts a pristine start-devmode.sh shortly AFTER
#      running it -> re-patch so the NEXT boot is hooked
#   2) a daemon spawned at boot+3s can stay deaf to connections (children
#      reset before the banner; cause never surfaced - LG kernel/network
#      voodoo). Daemons started once boot has settled have ALWAYS worked,
#      same binary, same options, same port. So: respawn sshd once at +150s.
(
    sleep 150
    patch_start_devmode
    p=$(cat /var/run/sshd.pid 2>/dev/null)
    if [ -n "$p" ]; then
        c=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
        case "$c" in
            *"sshd -f /dev/null"*)
                kill "$p" 2>/dev/null
                log "boot sshd (pid $p) replaced by post-boot respawn"
                # give the old daemon a moment to die AND release :22
                i=0
                while port22_up && [ $i -lt 4 ]; do sleep 2; i=$((i + 1)); done
                port22_up || start_sshd
                ;;
        esac
    fi
) &
