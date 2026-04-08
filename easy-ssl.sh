#!/bin/bash
#
# Script Name: easyssl
# Description: Simple and automated SSL management for Nginx using Certbot.
#              Supports auto-renew, Docker-friendly stop/start, DNS verification,
#              interactive domain picker, zero-downtime nginx plugin, and status dashboard.
# Author: chuisme
# Author URI: https://chuis.me
# License: MIT
#

EASYSSL_VERSION="1.3.0"

# ─── Config ───────────────────────────────────────────────────────────────────
CONFIG_FILE="/etc/easyssl/easyssl.conf"
AUTO_NGINX_CONFIG="disabled"
EMAIL=""

function load_config {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
}

function save_config {
    sudo mkdir -p /etc/easyssl
    sudo tee "$CONFIG_FILE" > /dev/null <<EOF
EMAIL="$EMAIL"
AUTO_NGINX_CONFIG="$AUTO_NGINX_CONFIG"
EOF
}

function ensure_email {
    if [ -z "$EMAIL" ] || [ "$EMAIL" = "__EMAIL_PLACEHOLDER__" ]; then
        echo ""
        echo "No email configured. An email is required for Let's Encrypt notifications."
        read -p "Enter your email address: " EMAIL
        save_config
        echo "Email saved to $CONFIG_FILE"
        echo ""
    fi
}

load_config

# ─── OS Detection ─────────────────────────────────────────────────────────────
if [ -f /etc/debian_version ]; then
    OS="debian"
elif [ -f /etc/redhat-release ]; then
    OS="redhat"
else
    echo "Unsupported OS. Please install certbot manually."
    exit 1
fi

# ─── Helpers ──────────────────────────────────────────────────────────────────

function install_certbot {
    if ! command -v certbot &> /dev/null; then
        echo "Certbot not found. Installing..."
        if [ "$OS" = "debian" ]; then
            sudo apt-get update -q
            sudo apt-get install certbot -y
        elif [ "$OS" = "redhat" ]; then
            sudo yum install epel-release -y
            sudo yum install certbot -y
        fi
    fi

    # Try to install nginx plugin for zero-downtime cert issuance
    if ! certbot plugins 2>/dev/null | grep -qi "nginx"; then
        echo "Installing certbot nginx plugin..."
        if [ "$OS" = "debian" ]; then
            sudo apt-get install python3-certbot-nginx -y 2>/dev/null || true
        elif [ "$OS" = "redhat" ]; then
            sudo yum install python3-certbot-nginx -y 2>/dev/null || true
        fi
    fi
}

function has_nginx_plugin {
    certbot plugins 2>/dev/null | grep -qi "nginx"
}

# Run certbot with best available method. $1=domain, $2=extra flags (e.g. --force-renewal --dry-run)
function run_certbot {
    local domain="$1"
    local extra_flags="${2:-}"

    if has_nginx_plugin; then
        echo "Using certbot nginx plugin (zero downtime)..."
        sudo certbot certonly --nginx -d "$domain" --non-interactive --agree-tos -m "$EMAIL" $extra_flags
    else
        echo "Nginx plugin not available. Using standalone mode (Nginx will stop briefly)..."
        local containers
        containers=$(sudo docker ps --filter "expose=80" --format "{{.ID}}" 2>/dev/null)
        if [ -n "$containers" ]; then
            echo "Stopping Docker containers using port 80..."
            for c in $containers; do sudo docker stop "$c"; done
        fi
        echo "Stopping Nginx..."
        sudo systemctl stop nginx

        sudo certbot certonly --standalone -d "$domain" --non-interactive --agree-tos -m "$EMAIL" $extra_flags
        local result=$?

        if [ -n "$containers" ]; then
            echo "Restarting Docker containers..."
            for c in $containers; do sudo docker start "$c"; done
        fi
        echo "Starting Nginx..."
        sudo systemctl start nginx

        return $result
    fi
}

# Interactive domain picker — sets $DOMAIN globally. Returns 1 if no domains found.
function pick_domain {
    local prompt="${1:-Select a domain}"
    local base_path="/etc/letsencrypt/live"
    local domains=()

    while IFS= read -r d; do
        domains+=("$d")
    done < <(sudo ls "$base_path" 2>/dev/null | grep -v README)

    if [ "${#domains[@]}" -eq 0 ]; then
        return 1
    fi

    echo ""
    echo "$prompt:"
    for i in "${!domains[@]}"; do
        printf "  %2d. %s\n" "$((i+1))" "${domains[$i]}"
    done
    echo ""

    while true; do
        read -p "Enter number (1-${#domains[@]}): " num
        if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#domains[@]}" ]; then
            DOMAIN="${domains[$((num-1))]}"
            echo "Selected: $DOMAIN"
            return 0
        fi
        echo "Invalid selection. Please try again."
    done
}

# DNS check — warns if domain doesn't resolve to this server's IP
function check_domain_dns {
    local domain="$1"
    echo "Checking DNS for $domain..."

    local server_ip
    server_ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null \
        || curl -s --max-time 5 api.ipify.org 2>/dev/null \
        || curl -s --max-time 5 icanhazip.com 2>/dev/null)

    local domain_ip
    domain_ip=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | head -1)

    if [ -z "$server_ip" ]; then
        echo "Warning: Could not detect this server's public IP. Skipping DNS check."
        return 0
    fi

    if [ -z "$domain_ip" ]; then
        echo ""
        echo "Warning: Cannot resolve $domain. DNS may not be configured yet."
        read -p "Continue anyway? (y/n): " CONFIRM
        [[ "$CONFIRM" =~ ^[Yy]$ ]]
        return $?
    fi

    if [ "$server_ip" = "$domain_ip" ]; then
        echo "DNS OK: $domain → $domain_ip"
        return 0
    else
        echo ""
        echo "Warning: $domain resolves to $domain_ip"
        echo "         This server's IP is     $server_ip"
        echo "         DNS may not be pointing to this server."
        read -p "Continue anyway? (y/n): " CONFIRM
        [[ "$CONFIRM" =~ ^[Yy]$ ]]
        return $?
    fi
}

# ─── Features ─────────────────────────────────────────────────────────────────

function add_domain {
    read -p "Enter the domain name: " DOMAIN
    sudo mkdir -p /etc/nginx/ssl/$DOMAIN
    echo "Directory /etc/nginx/ssl/$DOMAIN created."
}

function install_ssl {
    LOG_FILE="/var/log/easyssl.log"
    exec > >(sudo tee -a "$LOG_FILE") 2>&1

    ensure_email
    read -p "Enter the domain name: " DOMAIN
    install_certbot

    check_domain_dns "$DOMAIN" || return 1

    sudo mkdir -p /etc/nginx/ssl/$DOMAIN
    run_certbot "$DOMAIN" || return 1

    sudo cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem /etc/nginx/ssl/$DOMAIN/fullchain.pem
    sudo cp /etc/letsencrypt/live/$DOMAIN/privkey.pem /etc/nginx/ssl/$DOMAIN/privkey.pem
    echo "SSL certificates copied to /etc/nginx/ssl/$DOMAIN/."

    if [ "$AUTO_NGINX_CONFIG" = "enabled" ]; then
        echo "Creating nginx conf.d file for $DOMAIN..."
        sudo curl -fsSL https://raw.githubusercontent.com/chuismee/easy-ssl/main/conf.d.example -o /tmp/conf.d.example
        sudo sed "s|__DOMAIN__|$DOMAIN|g" /tmp/conf.d.example | sudo tee /etc/nginx/conf.d/$DOMAIN.conf > /dev/null
        sudo rm -f /tmp/conf.d.example
        echo "✅ /etc/nginx/conf.d/$DOMAIN.conf created."
        echo "Testing Nginx configuration..."
        sudo nginx -t && sudo systemctl reload nginx
    else
        echo "⚠️  Auto Nginx config is disabled. Skipping conf.d generation."
        sudo systemctl reload nginx 2>/dev/null || sudo systemctl start nginx 2>/dev/null || true
    fi
}

function dry_run_ssl {
    ensure_email
    read -p "Enter the domain name to test: " DOMAIN
    install_certbot

    check_domain_dns "$DOMAIN" || return 1

    echo ""
    echo "Running certbot dry-run for $DOMAIN (no certificate will be issued)..."
    echo ""

    run_certbot "$DOMAIN" "--dry-run"
    local result=$?

    echo ""
    if [ "$result" -eq 0 ]; then
        echo "✅ Dry-run successful. SSL can be issued for $DOMAIN."
    else
        echo "❌ Dry-run failed. Check the output above for details."
    fi
}

function renew_ssl {
    LOG_FILE="/var/log/easyssl.log"
    exec > >(sudo tee -a "$LOG_FILE") 2>&1

    ensure_email

    if ! pick_domain "Select domain to renew"; then
        read -p "No domains found via picker. Enter domain name manually: " DOMAIN
    fi

    install_certbot
    run_certbot "$DOMAIN" "--force-renewal" || return 1

    sudo cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem /etc/nginx/ssl/$DOMAIN/fullchain.pem
    sudo cp /etc/letsencrypt/live/$DOMAIN/privkey.pem /etc/nginx/ssl/$DOMAIN/privkey.pem
    echo "SSL renewed and copied to /etc/nginx/ssl/$DOMAIN/."
    sudo systemctl reload nginx 2>/dev/null || sudo systemctl start nginx 2>/dev/null || true
}

function check_ssl_expiry {
    local base_path="/etc/letsencrypt/live"

    if [ ! -d "$base_path" ]; then
        echo "No certificates found in $base_path."
        return
    fi

    echo "SSL certificate expiry:"
    echo "--------------------------------------"

    for domain in $(sudo ls "$base_path" | grep -v README); do
        cert_file="$base_path/$domain/cert.pem"
        if sudo test -f "$cert_file"; then
            expiry_date=$(sudo openssl x509 -enddate -noout -in "$cert_file" | cut -d= -f2)
            expiry_seconds=$(date -d "$expiry_date" +%s)
            now_seconds=$(date +%s)
            days_left=$(( (expiry_seconds - now_seconds) / 86400 ))

            if [ "$days_left" -le 30 ]; then
                printf "\033[1;31m%-30s : %s (%d days left)\033[0m\n" "$domain" "$expiry_date" "$days_left"
            else
                printf "%-30s : %s (%d days left)\n" "$domain" "$expiry_date" "$days_left"
            fi
        else
            echo "$domain : Certificate file not found."
        fi
    done
    echo "--------------------------------------"
}

function auto_check_and_renew {
    local base_path="/etc/letsencrypt/live"

    if [ -z "$EMAIL" ]; then
        echo "ERROR: Email not configured. Run 'easyssl' interactively to set up email first."
        return 1
    fi

    install_certbot

    if [ ! -d "$base_path" ]; then
        echo "No certificates found in $base_path."
        return
    fi

    echo "===== $(date '+%Y-%m-%d %H:%M:%S') Auto-renew check ====="

    for domain in $(sudo ls "$base_path" | grep -v README); do
        cert_file="$base_path/$domain/cert.pem"

        if sudo test -f "$cert_file"; then
            expiry_date=$(sudo openssl x509 -enddate -noout -in "$cert_file" | cut -d= -f2)
            expiry_seconds=$(date -d "$expiry_date" +%s)
            now_seconds=$(date +%s)
            days_left=$(( (expiry_seconds - now_seconds) / 86400 ))

            printf "%-30s : %d days left\n" "$domain" "$days_left"

            if [ "$days_left" -le 15 ]; then
                echo ">>> Renewing $domain..."
                run_certbot "$domain" "--force-renewal"
                sudo cp /etc/letsencrypt/live/$domain/fullchain.pem /etc/nginx/ssl/$domain/fullchain.pem
                sudo cp /etc/letsencrypt/live/$domain/privkey.pem /etc/nginx/ssl/$domain/privkey.pem
                sudo systemctl reload nginx 2>/dev/null || true
                echo ">>> $domain renewed."
            fi
        else
            echo "$domain : cert.pem not found."
        fi
    done
}

function status_dashboard {
    local base_path="/etc/letsencrypt/live"

    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│                    EasySSL Status Dashboard                      │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    echo ""
    printf "  %-14s : %s\n" "Version" "$EASYSSL_VERSION"
    printf "  %-14s : %s\n" "Email" "${EMAIL:-not configured}"

    if sudo crontab -l 2>/dev/null | grep -q "easyssl"; then
        printf "  %-14s : %s\n" "Auto Renew" "enabled (cron active)"
    else
        printf "  %-14s : %s\n" "Auto Renew" "disabled"
    fi

    printf "  %-14s : %s\n" "Nginx Config" "$AUTO_NGINX_CONFIG"

    if has_nginx_plugin; then
        printf "  %-14s : %s\n" "Certbot Mode" "nginx plugin (zero downtime)"
    else
        printf "  %-14s : %s\n" "Certbot Mode" "standalone (requires Nginx stop)"
    fi
    echo ""

    local domains=()
    while IFS= read -r d; do
        domains+=("$d")
    done < <(sudo ls "$base_path" 2>/dev/null | grep -v README)

    if [ "${#domains[@]}" -eq 0 ]; then
        echo "  No managed domains found."
        return
    fi

    printf "  %-32s %-8s %-12s %-10s\n" "DOMAIN" "DAYS" "STATUS" "NGINX CONF"
    printf "  %-32s %-8s %-12s %-10s\n" "────────────────────────────────" "────────" "────────────" "──────────"

    for domain in "${domains[@]}"; do
        local cert_file="$base_path/$domain/cert.pem"
        local days_left="N/A"
        local status="no cert"
        local color=""

        if sudo test -f "$cert_file"; then
            local expiry_date
            expiry_date=$(sudo openssl x509 -enddate -noout -in "$cert_file" | cut -d= -f2)
            local expiry_seconds now_seconds
            expiry_seconds=$(date -d "$expiry_date" +%s)
            now_seconds=$(date +%s)
            days_left=$(( (expiry_seconds - now_seconds) / 86400 ))

            if [ "$days_left" -le 0 ]; then
                status="EXPIRED"; color="\033[1;31m"
            elif [ "$days_left" -le 15 ]; then
                status="critical"; color="\033[1;31m"
            elif [ "$days_left" -le 30 ]; then
                status="expiring"; color="\033[1;33m"
            else
                status="ok"; color=""
            fi
        fi

        local nginx_conf="no"
        [ -f "/etc/nginx/conf.d/$domain.conf" ] && nginx_conf="yes"

        if [ -n "$color" ]; then
            printf "  ${color}%-32s %-8s %-12s %-10s\033[0m\n" "$domain" "$days_left" "$status" "$nginx_conf"
        else
            printf "  %-32s %-8s %-12s %-10s\n" "$domain" "$days_left" "$status" "$nginx_conf"
        fi
    done

    echo ""
    echo "  Total: ${#domains[@]} domain(s)"
}

function remove_domain {
    if ! pick_domain "Select domain to remove"; then
        read -p "No domains found via picker. Enter domain name manually: " DOMAIN
    fi

    echo ""
    echo "The following will be deleted:"
    echo "  - /etc/nginx/ssl/$DOMAIN/"
    echo "  - /etc/nginx/conf.d/$DOMAIN.conf (if exists)"
    echo "  - Let's Encrypt certificate for $DOMAIN"
    echo ""
    read -p "Are you sure you want to remove $DOMAIN? (y/n): " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; return; }

    if [ -d "/etc/nginx/ssl/$DOMAIN" ]; then
        sudo rm -rf /etc/nginx/ssl/$DOMAIN
        echo "Removed /etc/nginx/ssl/$DOMAIN"
    else
        echo "/etc/nginx/ssl/$DOMAIN not found, skipping."
    fi

    if [ -f "/etc/nginx/conf.d/$DOMAIN.conf" ]; then
        sudo rm -f /etc/nginx/conf.d/$DOMAIN.conf
        echo "Removed /etc/nginx/conf.d/$DOMAIN.conf"
    else
        echo "/etc/nginx/conf.d/$DOMAIN.conf not found, skipping."
    fi

    if sudo certbot certificates 2>/dev/null | grep -q "Domains:.*$DOMAIN"; then
        echo "Deleting Let's Encrypt certificate for $DOMAIN..."
        sudo certbot delete --cert-name "$DOMAIN" --non-interactive
        echo "Let's Encrypt certificate deleted."
    else
        echo "No Let's Encrypt certificate found for $DOMAIN, skipping."
    fi

    echo "Reloading Nginx..."
    sudo nginx -t && sudo systemctl reload nginx
    echo "Domain $DOMAIN has been fully removed."
}

function add_cron_auto_renew {
    CRON_CMD="/usr/local/bin/easyssl 5"
    CRON_JOB="0 3 * * * $CRON_CMD >> /var/log/easyssl.log 2>&1"

    if sudo crontab -l 2>/dev/null | grep -F "$CRON_CMD" &>/dev/null; then
        echo "Cron job already exists."
        return
    fi

    (sudo crontab -l 2>/dev/null; echo "$CRON_JOB") | sudo crontab -
    echo "Cron job added: runs daily at 3:00 AM"
}

function remove_cron_auto_renew {
    CRON_CMD="/usr/local/bin/easyssl 5"
    sudo crontab -l 2>/dev/null | grep -vF "$CRON_CMD" | sudo crontab -
    echo "Auto-renew cron job removed."
}

function view_auto_renew_log {
    LOG_FILE="/var/log/easyssl.log"
    echo "===== EasySSL Log ====="

    if [ ! -f "$LOG_FILE" ]; then
        echo "Log file not found: $LOG_FILE"
        echo "Cron job may not have run yet."
        return
    fi

    echo "1. View full log"
    echo "2. View last 50 lines (recommended)"
    echo "3. Follow log in realtime (like tail -f)"
    read -p "Choose an option: " LOG_CHOICE

    case $LOG_CHOICE in
        1) sudo less "$LOG_FILE" ;;
        2) sudo tail -n 50 "$LOG_FILE" ;;
        3) echo "Press CTRL+C to stop..."; sudo tail -f "$LOG_FILE" ;;
        *) echo "Invalid choice." ;;
    esac
}

function manage_nginx_config {
    echo "Current: AUTO_NGINX_CONFIG=$AUTO_NGINX_CONFIG"

    if [ "$AUTO_NGINX_CONFIG" = "disabled" ]; then
        echo "This will overwrite /etc/nginx/nginx.conf with EasySSL template."
        read -p "Enable and overwrite nginx.conf? (y/n): " CONFIRM
        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
            if [ ! -f /etc/nginx/nginx.conf.default ]; then
                sudo cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.default
                echo "Backup created: /etc/nginx/nginx.conf.default"
            fi
            sudo curl -fsSL https://raw.githubusercontent.com/chuismee/easy-ssl/main/nginx.conf.example -o /etc/nginx/nginx.conf
            echo "✅ nginx.conf updated from template."
            sudo nginx -t && sudo systemctl reload nginx
            AUTO_NGINX_CONFIG="enabled"
            save_config
            echo "✅ Auto nginx config ENABLED."
        else
            echo "Aborted."
        fi
    else
        echo "You are about to DISABLE auto nginx config and restore backup."
        read -p "Restore old nginx.conf? (y/n): " CONFIRM
        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
            if [ -f /etc/nginx/nginx.conf.default ]; then
                sudo mv /etc/nginx/nginx.conf.default /etc/nginx/nginx.conf
                sudo nginx -t && sudo systemctl reload nginx
                echo "✅ nginx.conf restored."
            else
                echo "⚠️  No backup found. Skipping restore."
            fi
            AUTO_NGINX_CONFIG="disabled"
            save_config
            echo "✅ Auto nginx config DISABLED."
        else
            echo "Aborted."
        fi
    fi
}

function update_easyssl {
    echo "Current version: $EASYSSL_VERSION"
    echo "Checking for updates..."

    TMP_FILE="/tmp/easyssl_latest"
    if ! sudo curl -fsSL https://raw.githubusercontent.com/chuismee/easy-ssl/main/easy-ssl.sh -o "$TMP_FILE"; then
        echo "Failed to download latest version."
        return 1
    fi

    echo "Backing up current version..."
    sudo cp /usr/local/bin/easyssl "/usr/local/bin/easyssl.bak.$(date +%F_%T)"
    sudo mv "$TMP_FILE" /usr/local/bin/easyssl
    sudo chmod +x /usr/local/bin/easyssl
    echo "Updated successfully. Run 'easyssl' to use the new version."
}

function uninstall_easyssl {
    echo ""
    echo "This will uninstall EasySSL from this server."
    echo "SSL certificates, Nginx config, and certbot will NOT be deleted."
    echo ""
    read -p "Are you sure you want to uninstall EasySSL? (y/n): " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; return; }

    # Remove cron job
    CRON_CMD="/usr/local/bin/easyssl 5"
    sudo crontab -l 2>/dev/null | grep -vF "$CRON_CMD" | sudo crontab -
    echo "Auto-renew cron job removed."

    # Remove config directory
    if [ -d "/etc/easyssl" ]; then
        sudo rm -rf /etc/easyssl
        echo "Config removed: /etc/easyssl"
    fi

    # Optionally remove log
    read -p "Also delete /var/log/easyssl.log? (y/n): " DEL_LOG
    if [[ "$DEL_LOG" =~ ^[Yy]$ ]]; then
        sudo rm -f /var/log/easyssl.log
        echo "Log file removed."
    fi

    # Remove backup binaries
    sudo rm -f /usr/local/bin/easyssl.bak.* 2>/dev/null || true

    # Remove the binary last (terminates this running script)
    echo "EasySSL uninstalled. Your SSL certs and Nginx config are unchanged."
    sudo rm -f /usr/local/bin/easyssl
}

# ─── Entry Point ──────────────────────────────────────────────────────────────

if [ "$1" = "update" ]; then
    update_easyssl
    exit 0
fi

if [ "$1" = "status" ]; then
    status_dashboard
    exit 0
fi

if [ -n "$1" ]; then
    CHOICE="$1"
else
    echo ""
    echo "  EasySSL v$EASYSSL_VERSION"
    echo "  Email      : ${EMAIL:-not configured}"
    if sudo crontab -l 2>/dev/null | grep -q "easyssl"; then
        echo "  Auto Renew : enabled"
    else
        echo "  Auto Renew : disabled"
    fi
    echo "  Nginx Conf : $AUTO_NGINX_CONFIG"
    echo ""
    echo "  Select an option:"
    echo "   1. Add domain"
    echo "   2. Remove domain"
    echo "   3. Install SSL"
    echo "   4. Renew SSL"
    echo "   5. Auto check & renew if expiring"
    echo "   6. Check SSL certificate expiry"
    echo "   7. Add cron job for auto renew"
    echo "   8. Remove cron job for auto renew"
    echo "   9. View log"
    echo "  10. Manage nginx config (enable/disable + restore)"
    echo "  11. Uninstall EasySSL"
    echo ""

    read -p "Enter your choice: " CHOICE
fi

case $CHOICE in
    1) add_domain ;;
    2) remove_domain ;;
    3) install_ssl ;;
    4) renew_ssl ;;
    5) auto_check_and_renew ;;
    6) check_ssl_expiry ;;
    7) add_cron_auto_renew ;;
    8) remove_cron_auto_renew ;;
    9) view_auto_renew_log ;;
    10) manage_nginx_config ;;
    11) uninstall_easyssl ;;
    *) echo "Invalid choice. Exiting." ;;
esac
