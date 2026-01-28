# easyssl

## Description

A simple, automated Bash tool to manage SSL certificates using Certbot and Nginx.  
Supports auto-renew, Docker-friendly stop/start, cron job auto-check, and flexible Nginx configuration management.  
Works seamlessly on multiple Linux distributions including Ubuntu, Debian, CentOS, Rocky Linux, AlmaLinux, and more.

## Features

- Easily install and configure SSL certificates
- Manual or automatic renewal support
- Check expiry for all domains in one command
- Automatically stop/start Docker containers using port 80 during renewal
- Setup cron job for automatic renewal checks
- Manage Nginx configuration:
  - Automatically update `nginx.conf` from template with backup & restore options
  - Auto-generate `conf.d` configurations for each domain after SSL installation
- Compatible with most popular Linux distributions (Ubuntu, Debian, CentOS, Rocky Linux, AlmaLinux, etc.)

## Installation
Install directly (1-line quick install):
```bash
curl -fsSL https://raw.githubusercontent.com/chuismee/easy-ssl/main/install.sh | sudo bash -s your@email.com
```
Or download first:
```bash
curl -fsSL https://raw.githubusercontent.com/chuismee/easy-ssl/main/install.sh -o install.sh
sudo bash install.sh
```
## Usage
After installation, simply run:

```bash
easyssl
```

## Menu options:
1. Add domain
2. Install SSL
3. Renew SSL
4. Check SSL certificate expiry
5. Auto check & renew if expiring
6. Add cron job for auto renew
7. Remove cron job for auto renew
8. View log
9. Manage nginx config (enable/disable + restore)