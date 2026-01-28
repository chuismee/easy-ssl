#!/bin/bash
#
# Script Name: easyssl
# Description: Simple and automated SSL management for Nginx using Certbot. Supports auto-renew and Docker-friendly stop/start.
# Author: chuisme
# Author URI: https://chuis.me
# License: MIT
#

TARGET_PATH="/usr/local/bin/easyssl"
EASY_SSL_URL="https://raw.githubusercontent.com/chuismee/easy-ssl/main/easy-ssl.sh"

if [[ -n "$1" ]]; then
    USER_EMAIL="$1"
else
    read -p "Enter your email to use for SSL registration: " USER_EMAIL
fi

if [[ -z "$USER_EMAIL" ]]; then
    echo "Email is required. Exiting."
    exit 1
fi

echo "Downloading EasySSL ..."
sudo curl -fsSL "$EASY_SSL_URL" -o "$TARGET_PATH"

sudo sed -i "s|EMAIL=\"__EMAIL_PLACEHOLDER__\"|EMAIL=\"$USER_EMAIL\"|g" "$TARGET_PATH"

sudo chmod +x "$TARGET_PATH"

if ! grep -q "alias easyssl=" ~/.bashrc; then
    echo "alias easyssl='/usr/local/bin/easyssl'" >> ~/.bashrc
else
    echo "Alias already exists in ~/.bashrc"
fi

source ~/.bashrc

CRON_CMD="/usr/local/bin/easyssl 5"
CRON_JOB="0 3 * * * $CRON_CMD >> /var/log/easyssl.log 2>&1"
(sudo crontab -l 2>/dev/null; echo "$CRON_JOB") | sudo crontab -
echo "Cron job added: $CRON_JOB"

echo "AUTO RENEW: ENABLED"

INSTALLER_PATH="$(realpath "$0")"
rm -f "$INSTALLER_PATH"

echo "✅ Installation completed!"
echo "You can now run 'easyssl' from anywhere in your terminal."
