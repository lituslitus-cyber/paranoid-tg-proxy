#!/usr/bin/env bash
set -e

if [[ $EUID -ne 0 ]]; then
   echo "ОШИБКА: Скрипт нужно запускать с правами root (sudo)."
   exit 1
fi

DOMAIN=""
while getopts d: flag; do
    case "${flag}" in
        d) DOMAIN=${OPTARG};;
    esac
done

if [ -z "$DOMAIN" ]; then
    echo "ОШИБКА: Не указан домен. Использование: bash $0 -d tg.твойдомен.ru"
    exit 1
fi

echo "=== Начинаем параноидальную установку для $DOMAIN ==="

echo ">>> Установка зависимостей..."
apt update && apt upgrade -y
apt install -y nginx certbot python3-certbot-nginx ufw ipset fail2ban curl openssl apache2-utils

echo ">>> Настройка UFW..."
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

echo ">>> Установка скриптов блокировки сканеров..."
cat << 'INNER_EOF' > /usr/local/sbin/rkn-blocklist-update.sh
#!/usr/bin/env bash
set -euo pipefail
URLS=(
  https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list
  https://raw.githubusercontent.com/tread-lightly/CyberOK_Skipa_ips/refs/heads/main/lists/skipa_cidr.txt
)
EXTRA="85.142.100.0/24 46.161.48.0/22 95.215.0.0/24 45.91.64.0/24"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
for u in "${URLS[@]}"; do curl -fsSL --retry 3 --max-time 60 "$u" >> "$T/raw" || true; echo >> "$T/raw"; done
echo "$EXTRA" | tr ' ' '\n' >> "$T/raw"
sed -e 's/#.*//' -e 's/[[:space:]]//g' "$T/raw" | grep -E '^[0-9a-fA-F:.]+(/[0-9]{1,3})?$' | sort -u > "$T/all" || true
{
  echo "create rkn4_tmp hash:net family inet hashsize 4096 maxelem 131072"
  awk '!/:/{print "add rkn4_tmp "$0}' "$T/all"
} > "$T/restore"
ipset list -n rkn4 >/dev/null 2>&1 || ipset create rkn4 hash:net family inet hashsize 4096 maxelem 131072
ipset destroy rkn4_tmp 2>/dev/null || true
ipset restore -exist < "$T/restore"
ipset swap rkn4_tmp rkn4
ipset destroy rkn4_tmp
ipset save rkn4 > /etc/ipset-rkn.conf
INNER_EOF

chmod +x /usr/local/sbin/rkn-blocklist-update.sh
/usr/local/sbin/rkn-blocklist-update.sh || echo "Внимание: не удалось загрузить списки РКН, продолжаем..."

if ! grep -q "rkn4" /etc/ufw/before.rules; then
    sed -i '/-A ufw-before-input -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT/a \
# RKN/gov blocklist\n-A ufw-before-input -m set --match-set rkn4 src -j DROP' /etc/ufw/before.rules
    ufw reload
fi

echo ">>> Создание сайта-заглушки..."
mkdir -p /var/www/$DOMAIN
cat << 'INNER_EOF' > /var/www/$DOMAIN/index.html
<!DOCTYPE html>
<html>
<head><title>System Administration Blog</title><meta charset="utf-8"></head>
<body style="font-family: sans-serif; padding: 40px; color: #333;">
    <h1>Under Construction</h1>
    <p>This page is currently being updated. Please check back later.</p>
</body>
</html>
INNER_EOF

PROXY_USER="tguser"
PROXY_PASS=$(openssl rand -hex 6)
htpasswd -bc /etc/nginx/.htpasswd $PROXY_USER $PROXY_PASS

echo ">>> Настройка Nginx и получение SSL..."
cat << INNER_EOF > /etc/nginx/sites-available/$DOMAIN
server {
    listen 80;
    server_name $DOMAIN;
    root /var/www/$DOMAIN;
    
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    auth_basic "Restricted Access";
    auth_basic_user_file /etc/nginx/.htpasswd;

    location / {
        proxy_pass https://web.telegram.org/;
        proxy_set_header Host web.telegram.org;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_ssl_server_name on;
        proxy_ssl_session_reuse off;
    }
}
INNER_EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/

systemctl stop nginx
certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN || true
systemctl start nginx

echo ""
echo "=========================================================="
echo "✅ УСТАНОВКА ЗАВЕРШЕНА!"
echo "👉 Адрес: https://$DOMAIN"
echo "👤 Логин: $PROXY_USER"
echo "🔑 Пароль: $PROXY_PASS"
echo "=========================================================="
