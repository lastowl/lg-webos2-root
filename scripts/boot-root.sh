#!/bin/sh
# Start a root SSH server on port 22 after towelroot achieves root.
# Runs as a background process launched from autoroot-boot.sh at boot.
# Waits for /tmp/rooted (created by towelroot), then starts sshd.

HOSTKEY=/media/developer/persist/ssh_host_rsa_key
SSHD=/opt/openssh/sbin/sshd
LOG=/tmp/autoroot.log

# Wait for root (up to 180s)
i=0
while [ ! -f /tmp/rooted ] && [ $i -lt 180 ]; do
    sleep 1
    i=$((i+1))
done

if [ ! -f /tmp/rooted ]; then
    echo "boot-root: timeout waiting for root" >> $LOG
    exit 1
fi

# Ensure root home and authorized_keys
mkdir -p /home/root/.ssh
chmod 700 /home/root/.ssh

# Fix host key permissions (persist dir can reset them to group-writable)
chmod 600 $HOSTKEY 2>/dev/null

# Only start if not already running (busybox netstat has no -p flag)
if ! netstat -tln 2>/dev/null | grep -q ":22 "; then
    $SSHD \
        -o StrictModes=no \
        -o PermitRootLogin=yes \
        -o PasswordAuthentication=no \
        -o PermitUserEnvironment=yes \
        -o UseDNS=no \
        -h $HOSTKEY \
        -p 22
    echo "boot-root: sshd started on port 22" >> $LOG
else
    echo "boot-root: sshd already running" >> $LOG
fi

# Start RPiPlay if available
if [ -x /media/developer/persist/rpiplay-start.sh ]; then
    /media/developer/persist/rpiplay-start.sh &
    echo "boot-root: rpiplay-start.sh launched" >> $LOG
fi
