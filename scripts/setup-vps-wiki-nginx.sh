#!/usr/bin/env bash
# One-time VPS setup: nginx on :80 for /utlas/wiki/ only. Does not touch bot, wg, xray.
set -euo pipefail

WIKI_ROOT="${WIKI_ROOT:-$HOME/utlas-wiki/www}"
NGINX_SITE="/etc/nginx/sites-available/utlas-wiki"

echo "Wiki root: $WIKI_ROOT"
mkdir -p "$WIKI_ROOT"
chmod -R a+rX "$(dirname "$WIKI_ROOT")" "$WIKI_ROOT" 2>/dev/null || true

if ! command -v nginx >/dev/null 2>&1; then
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nginx
fi

sudo tee "$NGINX_SITE" >/dev/null <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    location = / {
        return 404;
    }

    location /utlas/wiki/ {
        alias ${WIKI_ROOT}/;
        index index.html;
        try_files \$uri \$uri.html \$uri/ =404;
    }

    location = /utlas/wiki {
        return 301 /utlas/wiki/;
    }
}
EOF

sudo ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/utlas-wiki
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl enable nginx
sudo systemctl reload nginx

echo "OK: http://\$(curl -s -4 ifconfig.me 2>/dev/null || hostname -I | awk '{print \$1}')/utlas/wiki/"
