#!/bin/sh
# Autoroot at boot — triggered from jail_app.conf system command.
# Runs once per boot: runs exploit, starts root sshd + rpiplay,
# then re-patches jail_app.conf for the next boot (since start-devmode.sh
# overwrites it with the clean version from the download template).
LOCK=/tmp/.autoroot_boot_lock
PERSIST=/media/developer/persist
JAIL_CONF=/media/developer/jail_app.conf
MARKER="autoroot-boot"

# Only run once per boot
[ -f "$LOCK" ] && exit 0
touch "$LOCK"

# Skip if already rooted
if [ ! -f /tmp/rooted ]; then
    # Skip if exploit binary missing
    [ -x "$PERSIST/towelroot" ] || exit 0

    # Copy helper binaries to /tmp
    cp "$PERSIST/rootsh" /tmp/rootsh 2>/dev/null
    chmod 755 /tmp/rootsh 2>/dev/null
    cp "$PERSIST/dotrigger" /tmp/dotrigger 2>/dev/null
    chmod 755 /tmp/dotrigger 2>/dev/null

    # Run exploit
    "$PERSIST/towelroot" > /tmp/autoroot.log 2>&1
fi

# Start root sshd and rpiplay via boot-root.sh
if [ -f /tmp/rooted ] && [ -x "$PERSIST/boot-root.sh" ]; then
    "$PERSIST/boot-root.sh" >> /tmp/autoroot.log 2>&1
fi

# Re-patch jail_app.conf for the next boot.
# start-devmode.sh overwrites it with the clean template, so we wait
# for that to happen and then add our hook back.
(
    sleep 30
    if [ -f "$JAIL_CONF" ] && ! grep -q "$MARKER" "$JAIL_CONF"; then
        sed -i "/^include jail_device.conf/a\\
\\
# === AUTOROOT ===\\
system sh /media/developer/persist/$MARKER.sh \\&" "$JAIL_CONF"
    fi
) &
