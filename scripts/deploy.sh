#!/bin/bash
# deploy.sh - Run from your computer to deploy root to an LG webOS TV.
#
# Prerequisites:
#   - TV has Developer Mode enabled
#   - You can SSH to the TV (prisoner@<ip> -p 9922)
#
# Usage:
#   ./scripts/deploy.sh <tv-ip> [ssh-key] [port]
#
# Examples:
#   ./scripts/deploy.sh 192.168.1.100
#   ./scripts/deploy.sh 192.168.1.100 ~/.ssh/my_tv_key 9922

set -e

TV_IP="${1:?Usage: $0 <tv-ip> [ssh-key] [port]}"
SSH_KEY="${2:-}"
SSH_PORT="${3:-9922}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# SSH options
SSH_OPTS="-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa -o StrictHostKeyChecking=no -p $SSH_PORT"
if [ -n "$SSH_KEY" ]; then
    SSH_OPTS="$SSH_OPTS -i $SSH_KEY"
fi

SSH_CMD="ssh $SSH_OPTS prisoner@$TV_IP"
SCP_CMD="scp $SSH_OPTS"

# Check for prebuilt or compiled binaries
BIN_DIR=""
if [ -f "$PROJECT_DIR/prebuilt/towelroot" ]; then
    BIN_DIR="$PROJECT_DIR/prebuilt"
elif [ -f "$PROJECT_DIR/build/towelroot" ]; then
    BIN_DIR="$PROJECT_DIR/build"
else
    echo "[-] No binaries found. Build first with 'make' or 'make docker-build'."
    exit 1
fi

echo "=== LG webOS Root Deployment ==="
echo "TV: $TV_IP:$SSH_PORT"
echo "Binaries: $BIN_DIR"
echo

# Test SSH connection
echo "[*] Testing SSH connection..."
if ! $SSH_CMD 'echo ok' >/dev/null 2>&1; then
    echo "[-] Cannot connect. Check:"
    echo "    - TV is on and Developer Mode is enabled"
    echo "    - IP address and port are correct"
    echo "    - SSH key is correct (passphrase may be needed)"
    exit 1
fi
echo "[+] SSH connection OK"

# Get TV info
echo "[*] Checking TV..."
TV_INFO=$($SSH_CMD 'uname -r; cat /proc/version 2>/dev/null | head -1')
echo "[+] Kernel: $TV_INFO"

# Check if already rooted
if $SSH_CMD 'test -f /tmp/rooted' 2>/dev/null; then
    echo "[*] TV appears to already be rooted"
fi

# Create persist directory
echo "[*] Setting up persistent storage..."
$SSH_CMD 'mkdir -p /media/developer/persist 2>/dev/null; ls -la /media/developer/persist/' 2>/dev/null

# Upload binaries
echo "[*] Uploading binaries..."
$SCP_CMD "$BIN_DIR/towelroot" "prisoner@$TV_IP:/media/developer/persist/towelroot"
$SCP_CMD "$BIN_DIR/rootsh" "prisoner@$TV_IP:/media/developer/persist/rootsh"
$SCP_CMD "$BIN_DIR/dotrigger" "prisoner@$TV_IP:/media/developer/persist/dotrigger"
$SCP_CMD "$SCRIPT_DIR/ssh_wrapper.sh" "prisoner@$TV_IP:/media/developer/persist/ssh_wrapper.sh"
$SCP_CMD "$SCRIPT_DIR/boot-root.sh" "prisoner@$TV_IP:/media/developer/persist/boot-root.sh"
$SCP_CMD "$SCRIPT_DIR/install.sh" "prisoner@$TV_IP:/media/developer/persist/install.sh"
echo "[+] Files uploaded"

# Make executable
$SSH_CMD 'chmod 755 /media/developer/persist/*'

# Run exploit to get initial root
echo "[*] Running exploit for initial root..."
$SSH_CMD '
cp /media/developer/persist/rootsh /tmp/rootsh
cp /media/developer/persist/dotrigger /tmp/dotrigger
chmod 755 /tmp/rootsh /tmp/dotrigger
/media/developer/persist/towelroot > /tmp/exploit.log 2>&1 &
i=0
while [ ! -f /tmp/rooted ] && [ $i -lt 60 ]; do
    sleep 1
    i=$((i+1))
done
if [ -f /tmp/rooted ]; then
    echo "[+] Root achieved"
    cat /tmp/rooted
else
    echo "[-] Exploit timed out. Check /tmp/exploit.log"
    cat /tmp/exploit.log 2>/dev/null
    exit 1
fi
'

# Run installer
echo "[*] Installing persistence..."
$SSH_CMD '/tmp/rootsh -c "sh /media/developer/persist/install.sh"'

echo
echo "=== Deployment complete ==="
echo "Reboot the TV to test. After reboot, SSH in and run:"
echo "  ssh $SSH_OPTS prisoner@$TV_IP '/tmp/rootsh -c id'"
echo
echo "The exploit runs automatically on first SSH connection after boot (~5-8s)."
