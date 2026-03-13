#!/bin/bash
# =============================================================================
# Bootstrap Script — Phase 04: Initial Server Setup
# Run this on a fresh Ubuntu 22.04 to prepare for Ansible
# =============================================================================
set -euo pipefail

DEPLOY_USER="deploy"
SSH_PUB_KEY="${1:-}"

echo "=== vLLM Infrastructure Bootstrap ==="
echo "Host: $(hostname)"
echo "Date: $(date -u)"
echo ""

# Validate Ubuntu 22.04
if ! grep -q "22.04" /etc/lsb-release 2>/dev/null; then
    echo "ERROR: This script requires Ubuntu 22.04"
    exit 1
fi

# Update system
echo ">>> Updating system packages..."
apt update && apt upgrade -y

# Install minimal prerequisites
echo ">>> Installing prerequisites..."
apt install -y \
    openssh-server \
    python3 \
    python3-apt \
    sudo \
    curl \
    wget \
    ca-certificates \
    gnupg

# Create deploy user
echo ">>> Creating deploy user..."
if ! id "$DEPLOY_USER" &>/dev/null; then
    useradd -m -s /bin/bash -G sudo "$DEPLOY_USER"
    echo "$DEPLOY_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$DEPLOY_USER
    chmod 440 /etc/sudoers.d/$DEPLOY_USER
fi

# Setup SSH key
if [ -n "$SSH_PUB_KEY" ]; then
    echo ">>> Configuring SSH key for $DEPLOY_USER..."
    mkdir -p /home/$DEPLOY_USER/.ssh
    echo "$SSH_PUB_KEY" >> /home/$DEPLOY_USER/.ssh/authorized_keys
    chmod 700 /home/$DEPLOY_USER/.ssh
    chmod 600 /home/$DEPLOY_USER/.ssh/authorized_keys
    chown -R $DEPLOY_USER:$DEPLOY_USER /home/$DEPLOY_USER/.ssh
fi

# Add deploy user to required groups
usermod -aG sudo $DEPLOY_USER

# Basic SSH hardening (Ansible will complete this)
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl restart sshd

# Set timezone
timedatectl set-timezone UTC

# Enable firewall with SSH
ufw allow OpenSSH
ufw --force enable

echo ""
echo "=== Bootstrap Complete ==="
echo "Deploy user: $DEPLOY_USER"
echo "SSH: Key-only authentication"
echo "Firewall: UFW enabled (SSH allowed)"
echo ""
echo "Next: Run Ansible playbooks from control node"
echo "  ansible-playbook -i inventory/hosts.yml playbooks/gpu-runner-full.yml"
