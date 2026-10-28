#!/bin/sh
# install.sh - Run ON the TV (as prisoner with /tmp/rootsh available)
# Sets up persistent root: copies binaries, patches authorized_keys and jail_app.conf.
#
# Usage: /tmp/rootsh -c "sh /media/developer/persist/install.sh"

set -e

PERSIST_DIR="/media/developer/persist"
AUTH_KEYS="/media/developer/.ssh/authorized_keys"
WRAPPER="$PERSIST_DIR/ssh_wrapper.sh"
JAIL_CONF="/media/developer/jail_app.conf"

echo "=== LG webOS persistent root installer ==="

# verify we have root
if [ "$(id -u)" != "0" ]; then
    echo "[-] Must run as root. Use: /tmp/rootsh -c 'sh $0'"
    exit 1
fi

# verify binaries exist
for bin in towelroot rootsh dotrigger ssh_wrapper.sh autoroot-boot.sh boot-root.sh; do
    if [ ! -f "$PERSIST_DIR/$bin" ]; then
        echo "[-] Missing $PERSIST_DIR/$bin"
        exit 1
    fi
done

chmod 755 "$PERSIST_DIR/towelroot" "$PERSIST_DIR/rootsh" "$PERSIST_DIR/dotrigger"
chmod 755 "$PERSIST_DIR/ssh_wrapper.sh" "$PERSIST_DIR/autoroot-boot.sh" "$PERSIST_DIR/boot-root.sh"

echo "[+] Binaries verified in $PERSIST_DIR"

# patch authorized_keys
if [ ! -f "$AUTH_KEYS" ]; then
    echo "[-] No authorized_keys found at $AUTH_KEYS"
    exit 1
fi

if grep -q "ssh_wrapper.sh" "$AUTH_KEYS"; then
    echo "[*] authorized_keys already patched"
else
    # backup
    cp "$AUTH_KEYS" "$AUTH_KEYS.bak"
    echo "[+] Backup: $AUTH_KEYS.bak"

    # extract raw key (strip any existing options)
    RAWKEY=$(sed 's/^.*\(ssh-rsa .*\)/\1/' "$AUTH_KEYS")

    # write patched version
    echo "command=\"$WRAPPER\" $RAWKEY" > "$AUTH_KEYS"
    echo "[+] authorized_keys patched with command=$WRAPPER"
fi

# verify the patch looks right
if head -c 10 "$AUTH_KEYS" | grep -q "command="; then
    echo "[+] authorized_keys format OK"
else
    echo "[-] authorized_keys looks wrong, restoring backup"
    cp "$AUTH_KEYS.bak" "$AUTH_KEYS"
    exit 1
fi

# --- Root SSH server setup ---

echo "[*] Setting up root SSH server on port 22..."

# Generate persistent host key if needed
if [ ! -f "$PERSIST_DIR/ssh_host_rsa_key" ]; then
    /opt/openssh/bin/ssh-keygen -q -f "$PERSIST_DIR/ssh_host_rsa_key" -N "" -t rsa
    echo "[+] Generated SSH host key"
else
    echo "[*] SSH host key already exists"
fi
chmod 600 "$PERSIST_DIR/ssh_host_rsa_key"

# Install the same public key for root login
PUBKEY=$(sed 's/^command="[^"]*" //' "$AUTH_KEYS")
mkdir -p /home/root/.ssh
chmod 700 /home/root/.ssh
echo "$PUBKEY" > /home/root/.ssh/authorized_keys
chmod 644 /home/root/.ssh/authorized_keys
echo "[+] Root authorized_keys installed"

# --- Boot persistence via jail_app.conf ---
#
# The devmode service runs inside a jail. At boot, start-devmode.sh copies a
# clean jail_app.conf template from the jail's download/ directory, overwriting
# any edits. But the jailer reads jail_app.conf BEFORE that copy happens, and
# its "system" commands run on the host as root during jail setup.
#
# autoroot-boot.sh runs the exploit and starts root sshd, then re-patches
# jail_app.conf after start-devmode.sh overwrites it — creating a
# self-sustaining cycle across reboots.

MARKER="autoroot-boot"
echo "[*] Patching jail_app.conf for boot-time autoroot..."

if [ ! -f "$JAIL_CONF" ]; then
    echo "[-] jail_app.conf not found at $JAIL_CONF"
    echo "[-] Boot persistence not installed. Use SSH fallback (prisoner SSH triggers root)."
else
    if grep -q "$MARKER" "$JAIL_CONF"; then
        echo "[*] jail_app.conf already patched"
    else
        sed -i "/^include jail_device.conf/a\\
\\
# === AUTOROOT ===\\
system sh /media/developer/persist/$MARKER.sh \\&" "$JAIL_CONF"
        echo "[+] jail_app.conf patched"
    fi
fi

echo
echo "=== Installation complete ==="
echo
echo "Root persistence:"
echo "  - Exploit runs automatically at boot via jail_app.conf system command"
echo "  - Root SSH available on port 22 (~30-60s after boot)"
echo "  - Fallback: exploit also runs on prisoner SSH connect"
echo
echo "Usage:"
echo "  ssh -p 22 root@<tv-ip>                   # direct root SSH"
echo "  ssh -p 9922 prisoner@<tv-ip>              # prisoner (triggers root if needed)"
echo "  /tmp/rootsh -c 'command'                   # run as root from prisoner shell"
