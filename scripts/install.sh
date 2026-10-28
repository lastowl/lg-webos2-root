#!/bin/sh
# install.sh - Run ON the TV (as prisoner with /tmp/rootsh available)
# Sets up persistent root: copies binaries, patches authorized_keys.
#
# Usage: /tmp/rootsh -c "sh /media/developer/persist/install.sh"

set -e

PERSIST_DIR="/media/developer/persist"
AUTH_KEYS="/media/developer/.ssh/authorized_keys"
WRAPPER="$PERSIST_DIR/ssh_wrapper.sh"

echo "=== LG webOS persistent root installer ==="

# verify we have root
if [ "$(id -u)" != "0" ]; then
    echo "[-] Must run as root. Use: /tmp/rootsh -c 'sh $0'"
    exit 1
fi

# verify binaries exist
for bin in towelroot rootsh dotrigger ssh_wrapper.sh; do
    if [ ! -f "$PERSIST_DIR/$bin" ]; then
        echo "[-] Missing $PERSIST_DIR/$bin"
        exit 1
    fi
done

chmod 755 "$PERSIST_DIR/towelroot" "$PERSIST_DIR/rootsh" "$PERSIST_DIR/dotrigger"
chmod 755 "$PERSIST_DIR/ssh_wrapper.sh"

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

# Patch start-devmode.sh to run autoroot + root sshd at boot
DEVMODE_SCRIPT="/media/cryptofs/apps/usr/palm/services/com.palmdts.devmode.service/start-devmode.sh"
if [ -f "$DEVMODE_SCRIPT" ]; then
    if grep -q "boot-root" "$DEVMODE_SCRIPT"; then
        echo "[*] start-devmode.sh already patched"
    elif grep -q "^# === AUTOROOT" "$DEVMODE_SCRIPT"; then
        echo "[*] start-devmode.sh has AUTOROOT block, updating..."
        sed -i "/^# === AUTOROOT/,/^# === END AUTOROOT/c\\
# === AUTOROOT: run towelroot exploit at boot ===\\
if [ -x /media/developer/persist/towelroot ] && [ ! -f /tmp/rooted ]; then\\
    (\\
        cp /media/developer/persist/rootsh /tmp/rootsh\\
        chmod 755 /tmp/rootsh\\
        cp /media/developer/persist/dotrigger /tmp/dotrigger\\
        chmod 755 /tmp/dotrigger\\
        /media/developer/persist/towelroot > /tmp/autoroot.log 2>\&1 \&\\
    ) \&\\
    /media/developer/persist/boot-root.sh \&\\
fi\\
# === END AUTOROOT ===" "$DEVMODE_SCRIPT"
        echo "[+] start-devmode.sh patched with autoroot + root sshd"
    else
        echo "[*] Injecting AUTOROOT block into start-devmode.sh..."
        cp "$DEVMODE_SCRIPT" "$DEVMODE_SCRIPT.bak"
        sed -i '/^export LD_LIBRARY_PATH=/a\
\
# === AUTOROOT: run towelroot exploit at boot ===\
if [ -x /media/developer/persist/towelroot ] && [ ! -f /tmp/rooted ]; then\
    (\
        cp /media/developer/persist/rootsh /tmp/rootsh\
        chmod 755 /tmp/rootsh\
        cp /media/developer/persist/dotrigger /tmp/dotrigger\
        chmod 755 /tmp/dotrigger\
        /media/developer/persist/towelroot > /tmp/autoroot.log 2>\&1 \&\
    ) \&\
    /media/developer/persist/boot-root.sh \&\
fi\
# === END AUTOROOT ===' "$DEVMODE_SCRIPT"
        echo "[+] start-devmode.sh patched (backup at .bak)"
    fi
else
    echo "[-] start-devmode.sh not found, skipping boot hook"
fi

echo
echo "=== Installation complete ==="
echo
echo "Root persistence:"
echo "  - Exploit runs automatically at boot via start-devmode.sh"
echo "  - Root SSH available on port 22 (~30-60s after boot)"
echo "  - Fallback: exploit also runs on prisoner SSH connect"
echo
echo "Usage:"
echo "  ssh -p 22 root@<tv-ip>                   # direct root SSH"
echo "  ssh -p 9922 prisoner@<tv-ip>              # prisoner (triggers root if needed)"
echo "  /tmp/rootsh -c 'command'                   # run as root from prisoner shell"
