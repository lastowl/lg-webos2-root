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

echo
echo "=== Installation complete ==="
echo "After reboot, root activates on first SSH connection (~5-8s)."
echo "Use '/tmp/rootsh -c <cmd>' for root commands."
echo
echo "To test: reboot the TV, SSH in, wait a few seconds, then run:"
echo "  /tmp/rootsh -c id"
