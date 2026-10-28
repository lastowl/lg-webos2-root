#!/bin/sh
# Autoroot at boot — triggered from start-devmode.sh hook.
# Runs exploit, starts root sshd + rpiplay, then re-patches
# start-devmode.sh if appinstalld re-extracts the original.
LOCK=/tmp/.autoroot_boot_lock
PERSIST=/media/developer/persist
DEVMODE_SCRIPT=/media/cryptofs/apps/usr/palm/services/com.palmdts.devmode.service/start-devmode.sh
HOOK_MARKER="AUTOROOT BOOT HOOK"

[ -f "$LOCK" ] && exit 0
touch "$LOCK"

if [ ! -f /tmp/rooted ]; then
    [ -x "$PERSIST/towelroot" ] || exit 0
    cp "$PERSIST/rootsh" /tmp/rootsh 2>/dev/null
    chmod 755 /tmp/rootsh 2>/dev/null
    cp "$PERSIST/dotrigger" /tmp/dotrigger 2>/dev/null
    chmod 755 /tmp/dotrigger 2>/dev/null
    "$PERSIST/towelroot" > /tmp/autoroot.log 2>&1
fi

if [ -f /tmp/rooted ] && [ -x "$PERSIST/boot-root.sh" ]; then
    "$PERSIST/boot-root.sh" >> /tmp/autoroot.log 2>&1
fi

# Re-patch start-devmode.sh if appinstalld overwrites it
(
    i=0
    while [ $i -lt 600 ]; do
        sleep 10
        i=$((i + 10))
        if [ -f "$DEVMODE_SCRIPT" ] && ! grep -q "$HOOK_MARKER" "$DEVMODE_SCRIPT"; then
            sleep 5
            sed -i "/^set -x$/a\\
\\
# === $HOOK_MARKER ===\\
date > /media/developer/persist/boot-marker\\
if [ -x /media/developer/persist/autoroot-boot.sh ]; then\\
    /media/developer/persist/autoroot-boot.sh \&\\
fi\\
# === END AUTOROOT ===" "$DEVMODE_SCRIPT"
            echo "autoroot: re-patched start-devmode.sh at $(date)" >> /tmp/autoroot.log
            break
        fi
    done
) &
