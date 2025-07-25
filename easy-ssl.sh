#!/bin/bash
#
# Script Name: easyssl
# Description: Simple and automated SSL management for Nginx using Certbot. Supports auto-renew and Docker-friendly stop/start.
# Author: chuisme
# Author URI: https://chuis.me
# License: MIT
#

AUTO_NGINX_CONFIG="no"

if [ -f /etc/debian_version ]; then
    OS="debian"
elif [ -f /etc/redhat-release ]; then
    OS="redhat"
else
    echo "Unsupported OS. Please install certbot manually."
    exit 1
fi

EMAIL="__EMAIL_PLACEHOLDER__"

function install_certbot {
    if ! command -v certbot &> /dev/null; then
        echo "Certbot not found. Installing..."
        if [ "$OS" = "debian" ]; then
            sudo apt-get update
            sudo apt-get install certbot -y
        elif [ "$OS" = "redhat" ]; then
            sudo yum install epel-release -y
            sudo yum install certbot -y
        fi
    fi
}

function add_domain {
    read -p "Enter the domain name: " DOMAIN
    sudo mkdir -p /etc/nginx/ssl/$DOMAIN
    echo "Directory for $DOMAIN created successfully."
}

function install_ssl {
    read -p "Enter the domain name: " DOMAIN
    install_certbot

    echo "Stopping Docker containers using port 80..."
    containers=$(sudo docker ps --filter "expose=80" --format "{{.ID}}")
    if [ -n "$containers" ]; then
        for container in $containers; do
            sudo docker stop $container
        done
    else
        echo "No Docker containers using port 80 found."
    fi

    echo "Stopping Nginx..."
    sudo systemctl stop nginx

    sudo certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos -m $EMAIL

    sudo cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem /etc/nginx/ssl/$DOMAIN/fullchain.pem
    sudo cp /etc/letsencrypt/live/$DOMAIN/privkey.pem /etc/nginx/ssl/$DOMAIN/privkey.pem
    echo "SSL certificates for $DOMAIN have been copied to /etc/nginx/ssl/$DOMAIN/."

    if [ "$AUTO_NGINX_CONFIG" = "yes" ]; then
        echo "Creating nginx conf.d file for $DOMAIN..."
        sudo curl -fsSL https://raw.githubusercontent.com/chuismee/easy-ssl/main/conf.d.example -o /tmp/conf.d.example

        sudo sed "s|__DOMAIN__|$DOMAIN|g" /tmp/conf.d.example | sudo tee /etc/nginx/conf.d/$DOMAIN.conf > /dev/null

        sudo rm -f /tmp/conf.d.example
        echo "✅ /etc/nginx/conf.d/$DOMAIN.conf created."

        echo "Testing Nginx configuration..."
        sudo nginx -t
    else
        echo "⚠️ Auto Nginx config is disabled. Skipping conf.d generation."
    fi

    echo "Restarting Docker containers..."
    for container in $containers; do
        sudo docker start $container
    done

    echo "Restarting Nginx..."
    sudo systemctl start nginx
}

function renew_ssl {
    read -p "Enter the domain name: " DOMAIN
    install_certbot

    echo "Stopping Docker containers using port 80..."
    containers=$(sudo docker ps --filter "expose=80" --format "{{.ID}}")
    if [ -n "$containers" ]; then
        for container in $containers; do
            sudo docker stop $container
        done
    else
        echo "No Docker containers using port 80 found."
    fi

    echo "Stopping Nginx..."
    sudo systemctl stop nginx

    echo "Renewing SSL certificate for $DOMAIN..."
    sudo certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos --force-renewal -m $EMAIL

    sudo cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem /etc/nginx/ssl/$DOMAIN/fullchain.pem
    sudo cp /etc/letsencrypt/live/$DOMAIN/privkey.pem /etc/nginx/ssl/$DOMAIN/privkey.pem
    echo "SSL certificates for $DOMAIN have been renewed and copied to /etc/nginx/ssl/$DOMAIN/."

    echo "Restarting Docker containers..."
    for container in $containers; do
        sudo docker start $container
    done

    echo "Restarting Nginx..."
    sudo systemctl start nginx
}

function check_ssl_expiry {
    base_path="/etc/letsencrypt/live"

    if [ ! -d "$base_path" ]; then
        echo "No certificates found in $base_path."
        return
    fi

    echo "Checking SSL certificate expiry dates:"
    echo "--------------------------------------"

    for domain in $(sudo ls $base_path); do
        cert_file="$base_path/$domain/cert.pem"

        if sudo test -f "$cert_file"; then
            expiry_date=$(sudo openssl x509 -enddate -noout -in "$cert_file" | cut -d= -f2)
            expiry_seconds=$(date -d "$expiry_date" +%s)
            now_seconds=$(date +%s)
            days_left=$(( (expiry_seconds - now_seconds) / 86400 ))

            if [ "$days_left" -le 30 ]; then
                printf "\033[1;31m%-30s : Expires on %s (%d days left)\033[0m\n" "$domain" "$expiry_date" "$days_left"
            else
                printf "%-30s : Expires on %s (%d days left)\n" "$domain" "$expiry_date" "$days_left"
            fi
        else
            echo "$domain : Certificate file not found."
        fi
    done
    echo "--------------------------------------"
}

function auto_check_and_renew {
    base_path="/etc/letsencrypt/live"
    install_certbot

    if [ ! -d "$base_path" ]; then
        echo "No certificates found in $base_path."
        return
    fi

    echo "Checking and auto-renewing SSL certificates:"
    echo "---------------------------------------------"

    for domain in $(sudo ls $base_path); do
        cert_file="$base_path/$domain/cert.pem"

        if sudo test -f "$cert_file"; then
            expiry_date=$(sudo openssl x509 -enddate -noout -in "$cert_file" | cut -d= -f2)
            expiry_seconds=$(date -d "$expiry_date" +%s)
            now_seconds=$(date +%s)
            days_left=$(( (expiry_seconds - now_seconds) / 86400 ))

            printf "%-30s : Expires on %s (%d days left)\n" "$domain" "$expiry_date" "$days_left"

            if [ "$days_left" -le 15 ]; then
                echo ">>> Certificate for $domain is close to expiry. Renewing..."

                echo "Stopping Docker containers using port 80..."
                containers=$(sudo docker ps --filter "expose=80" --format "{{.ID}}")
                if [ -n "$containers" ]; then
                    for container in $containers; do
                        sudo docker stop $container
                    done
                fi

                echo "Stopping Nginx..."
                sudo systemctl stop nginx

                sudo certbot certonly --standalone -d $domain --non-interactive --agree-tos --force-renewal -m $EMAIL

                sudo cp /etc/letsencrypt/live/$domain/fullchain.pem /etc/nginx/ssl/$domain/fullchain.pem
                sudo cp /etc/letsencrypt/live/$domain/privkey.pem /etc/nginx/ssl/$domain/privkey.pem
                echo ">>> SSL certificates for $domain renewed and copied successfully."

                echo "Restarting Docker containers..."
                for container in $containers; do
                    sudo docker start $container
                done

                echo "Restarting Nginx..."
                sudo systemctl start nginx

                echo ">>> $domain has been renewed successfully."
                echo "---------------------------------------------"
            fi
        else
            echo "$domain : Certificate file not found."
        fi
    done
}

function add_cron_auto_renew {
    CRON_CMD="/usr/local/bin/easyssl 5"
    CRON_JOB="0 3 * * * $CRON_CMD >> /var/log/ssl_auto_renew.log 2>&1"

    if sudo crontab -l 2>/dev/null | grep -F "$CRON_CMD" &>/dev/null; then
        echo "Cron job already exists."
        return
    fi

    (sudo crontab -l 2>/dev/null; echo "$CRON_JOB") | sudo crontab -
    echo "Cron job added: $CRON_JOB"
}

function remove_cron_auto_renew {
    CRON_CMD="/usr/local/bin/easyssl 5"
    sudo crontab -l 2>/dev/null | grep -vF "$CRON_CMD" | sudo crontab -
    echo "Cron job removed (if it existed)."
}

function manage_nginx_config {
    echo "Current auto nginx config: $AUTO_NGINX_CONFIG"

    if [ "$AUTO_NGINX_CONFIG" = "no" ]; then
        echo "This will overwrite your /etc/nginx/nginx.conf with EasySSL template."
        read -p "Do you want to ENABLE and overwrite nginx.conf? (y/n): " CONFIRM
        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then

            if [ ! -f /etc/nginx/nginx.conf.default ]; then
                sudo cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.default
                echo "Backup created: /etc/nginx/nginx.conf.default"
            fi

            sudo curl -fsSL https://raw.githubusercontent.com/chuismee/easy-ssl/main/nginx.conf.example -o /etc/nginx/nginx.conf
            echo "✅ nginx.conf has been updated from template."

            echo "Testing nginx config..."
            sudo nginx -t && sudo systemctl reload nginx

            AUTO_NGINX_CONFIG="yes"
            echo "✅ Auto nginx config ENABLED."
        else
            echo "❌ Aborted. Auto nginx config remains disabled."
        fi
    else
        echo "You are about to DISABLE auto nginx config and restore default."
        read -p "Do you want to restore your old nginx.conf? (y/n): " CONFIRM
        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
            if [ -f /etc/nginx/nginx.conf.default ]; then
                sudo mv /etc/nginx/nginx.conf.default /etc/nginx/nginx.conf
                echo "✅ nginx.conf restored from backup."

                sudo nginx -t && sudo systemctl reload nginx
                echo "Nginx reloaded."
            else
                echo "⚠️ No backup found. Skipping restore."
            fi

            AUTO_NGINX_CONFIG="no"
            
            echo "✅ Auto nginx config DISABLED."
        else
            echo "❌ Aborted. Auto nginx config remains enabled."
        fi
    fi
}

if [ -n "$1" ]; then
    CHOICE="$1"
else
    echo "Current auto nginx config: $AUTO_NGINX_CONFIG"
    echo "Select an option:"
    echo "1. Add domain"
    echo "2. Install SSL"
    echo "3. Renew SSL"
    echo "4. Check SSL certificate expiry"
    echo "5. Auto check & renew if expiring"
    echo "6. Add cron job for auto renew"
    echo "7. Remove cron job for auto renew"
    echo "8. Manage nginx config (enable/disable + restore)"

    read -p "Enter your choice: " CHOICE
fi

case $CHOICE in
    1) add_domain ;;
    2) install_ssl ;;
    3) renew_ssl ;;
    4) check_ssl_expiry ;;
    5) auto_check_and_renew ;;
    6) add_cron_auto_renew ;;
    7) remove_cron_auto_renew ;;
    8) manage_nginx_config ;;
    *) echo "Invalid choice. Exiting." ;;
esac
