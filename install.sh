#!/bin/bash
#
# Script Name: easyssl installer
# Description: Simple and automated SSL management for Nginx using Certbot. Supports auto-renew and Docker-friendly stop/start.
# Author: chuisme
# Author URI: https://chuis.me
# License: MIT
#

TARGET_PATH="/usr/local/bin/easyssl"
CONFIG_FILE="/etc/easyssl/easyssl.conf"
EASY_SSL_URL="https://raw.githubusercontent.com/chuismee/easy-ssl/main/easy-ssl.sh"

# ─── Email ────────────────────────────────────────────────────────────────────
if [[ -n "$1" ]]; then
    USER_EMAIL="$1"
else
    read -p "Enter your email for SSL registration (Leave blank to configure later): " USER_EMAIL
fi

# ─── Download ─────────────────────────────────────────────────────────────────
echo "Downloading EasySSL..."
sudo curl -fsSL "$EASY_SSL_URL" -o "$TARGET_PATH"
sudo chmod +x "$TARGET_PATH"

# ─── Save config ──────────────────────────────────────────────────────────────
sudo mkdir -p /etc/easyssl
sudo tee "$CONFIG_FILE" > /dev/null <<EOF
EMAIL="$USER_EMAIL"
AUTO_NGINX_CONFIG="disabled"
EOF

if [[ -n "$USER_EMAIL" ]]; then
    echo "Email saved to $CONFIG_FILE"
else
    echo "⚠️  No email configured. EasySSL will ask for your email on first use."
fi

# ─── Alias ────────────────────────────────────────────────────────────────────
if ! grep -q "alias easyssl=" ~/.bashrc; then
    echo "alias easyssl='/usr/local/bin/easyssl'" >> ~/.bashrc
else
    echo "Alias already exists in ~/.bashrc"
fi

source ~/.bashrc

# ─── Firewall ─────────────────────────────────────────────────────────────────
echo "Opening ports 80 and 443..."
if command -v ufw &>/dev/null; then
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp
    echo "Ports 80 and 443 opened via ufw."
elif command -v firewall-cmd &>/dev/null; then
    sudo firewall-cmd --permanent --add-service=http
    sudo firewall-cmd --permanent --add-service=https
    sudo firewall-cmd --reload
    echo "Ports 80 and 443 opened via firewalld."
else
    echo "⚠️  No supported firewall found (ufw/firewalld). Please open ports 80 and 443 manually."
fi

# ─── Cron ─────────────────────────────────────────────────────────────────────
CRON_CMD="/usr/local/bin/easyssl 5"
CRON_JOB="0 3 * * * $CRON_CMD >> /var/log/easyssl.log 2>&1"

if sudo crontab -l 2>/dev/null | grep -qF "$CRON_CMD"; then
    echo "Auto-renew cron job already exists."
else
    (sudo crontab -l 2>/dev/null; echo "$CRON_JOB") | sudo crontab -
    echo "Auto-renew cron job added (runs daily at 3:00 AM)."
fi

# ─── Cleanup ──────────────────────────────────────────────────────────────────
INSTALLER_PATH="$(realpath "$0")"
rm -f "$INSTALLER_PATH"

echo ""
echo "✅ Installation completed!"
echo "   Run 'easyssl' from anywhere to get started."
echo "   Run 'easyssl status' to see an overview."
