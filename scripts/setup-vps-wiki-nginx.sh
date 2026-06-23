#!/usr/bin/env bash
# One-time VPS setup: nginx wiki on wg hub only (10.243.63.1:80). Does not touch bot, wg, xray.
set -euo pipefail

WIKI_ROOT="${WIKI_ROOT:-$HOME/utlas-wiki/www}"
WG_HUB_IP="${WG_HUB_IP:-10.243.63.1}"
NGINX_SITE="/etc/nginx/sites-available/utlas-wiki"
NGINX_BOT_MAP="/etc/nginx/conf.d/utlas-bot-block-map.conf"

echo "Wiki root: $WIKI_ROOT"
echo "Listen: ${WG_HUB_IP}:80 (WireGuard only)"
mkdir -p "$WIKI_ROOT"
chmod -R a+rX "$(dirname "$WIKI_ROOT")" "$WIKI_ROOT" 2>/dev/null || true

if ! command -v nginx >/dev/null 2>&1; then
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nginx
fi

sudo tee "$NGINX_BOT_MAP" >/dev/null <<'EOF'
# Optional extra guard if wiki is ever exposed on public :80 again.
map $http_user_agent $utlas_block_bot {
    default 0;
    "" 1;
    "-" 1;
    ~*googlebot 1;
    ~*bingbot 1;
    ~*yandex 1;
    ~*baiduspider 1;
    ~*duckduckbot 1;
    ~*slurp 1;
    ~*facebookexternalhit 1;
    ~*twitterbot 1;
    ~*linkedinbot 1;
    ~*embedly 1;
    ~*pinterest 1;
    ~*applebot 1;
    ~*petalbot 1;
    ~*semrush 1;
    ~*ahrefs 1;
    ~*dotbot 1;
    ~*rogerbot 1;
    ~*archive.org_bot 1;
    ~*wget 1;
    ~*python-requests 1;
    ~*go-http-client 1;
    ~*scrapy 1;
    ~*claudebot 1;
    ~*claude-user 1;
    ~*gptbot 1;
    ~*chatgpt-user 1;
    ~*anthropic 1;
    ~*bot 1;
    ~*crawl 1;
    ~*spider 1;
}
EOF

sudo tee "$NGINX_SITE" >/dev/null <<EOF
server {
    listen ${WG_HUB_IP}:80;
    listen 127.0.0.1:80;

    if (\$utlas_block_bot) {
        return 403;
    }

    location = /robots.txt {
        default_type text/plain;
        return 200 "User-agent: *\\nDisallow: /\\n";
    }

    location = / {
        return 404;
    }

    location /utlas/wiki/ {
        alias ${WIKI_ROOT}/;
        index index.html;
        try_files \$uri \$uri.html \$uri/ =404;
        add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet" always;
    }

    location = /utlas/wiki {
        return 301 /utlas/wiki/;
    }

    location / {
        return 404;
    }
}
EOF

sudo ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/utlas-wiki
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl enable nginx
sudo systemctl reload nginx

echo "OK (WireGuard): http://${WG_HUB_IP}/utlas/wiki/"
