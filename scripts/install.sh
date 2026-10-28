#!/bin/sh
# install.sh - Run ON the TV (as prisoner with /tmp/rootsh available)
# Sets up persistent root: copies binaries, patches authorized_keys and start-devmode.sh.
#
# Usage: /tmp/rootsh -c "sh /media/developer/persist/install.sh"

set -e

PERSIST_DIR="/media/developer/persist"
AUTH_KEYS="/media/developer/.ssh/authorized_keys"
WRAPPER="$PERSIST_DIR/ssh_wrapper.sh"
DEVMODE_SCRIPT="/media/cryptofs/apps/usr/palm/services/com.palmdts.devmode.service/start-devmode.sh"
HOOK_MARKER="AUTOROOT BOOT HOOK"

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

# --- Boot persistence via start-devmode.sh ---

echo "[*] Patching start-devmode.sh for boot-time autoroot..."

if [ ! -f "$DEVMODE_SCRIPT" ]; then
    echo "[-] start-devmode.sh not found at $DEVMODE_SCRIPT"
    echo "[-] Boot persistence not installed. Use SSH fallback (prisoner SSH triggers root)."
else
    if grep -q "$HOOK_MARKER" "$DEVMODE_SCRIPT"; then
        echo "[*] start-devmode.sh already patched"
    else
        cp "$DEVMODE_SCRIPT" "$DEVMODE_SCRIPT.orig" 2>/dev/null
        sed -i "/^set -x$/a\\
\\
# === $HOOK_MARKER ===\\
date > /media/developer/persist/boot-marker\\
if [ -x /media/developer/persist/autoroot-boot.sh ]; then\\
    /media/developer/persist/autoroot-boot.sh \&\\
fi\\
# === END AUTOROOT ===" "$DEVMODE_SCRIPT"
        echo "[+] start-devmode.sh patched"
    fi
fi

echo
echo "=== Installation complete ==="
echo
echo "Root persistence:"
echo "  - Exploit runs automatically at boot via start-devmode.sh hook"
echo "  - Root SSH available on port 22 (~30-60s after boot)"
echo "  - Fallback: exploit also runs on prisoner SSH connect"
echo
echo "Usage:"
echo "  ssh -p 22 root@<tv-ip>                   # direct root SSH"
echo "  ssh -p 9922 prisoner@<tv-ip>              # prisoner (triggers root if needed)"
echo "  /tmp/rootsh -c 'command'                   # run as root from prisoner shell"
