#!/usr/bin/env bash
# paranoid-tg-proxy v2
# Обёртка над telegramdesktop/tproxy-server (WEB proxy для Telegram)
# + блоклист сканеров на nftables, который переживает перезагрузку.
#
# Использование:
#   sudo bash install.sh -d proxy.example.com -e you@example.com -s /путь/к/сайту
#
# -d  домен (строчными, A-запись уже указывает на этот сервер)
# -e  почта для Let's Encrypt
# -s  каталог СВОЕГО статического сайта (обязателен index.html)
#
# Переменные окружения: TPROXY_REF (ветка или тег tproxy-server, по умолчанию master)

set -Eeuo pipefail
trap 'echo "ОШИБКА: строка $LINENO, код $?. Установка остановлена." >&2' ERR

REPO_URL="https://github.com/telegramdesktop/tproxy-server"
REPO_REF="${TPROXY_REF:-master}"
SRC_DIR="/opt/tproxy-server-src"
SECRET_FILE="/root/.tg-proxy-secret"
export DEBIAN_FRONTEND=noninteractive

die()  { echo "ОШИБКА: $*" >&2; exit 1; }
info() { echo ">>> $*"; }
usage() { die "Использование: sudo bash $0 -d proxy.example.com -e you@example.com -s /путь/к/сайту"; }

DOMAIN=""; EMAIL=""; SITE_DIR=""
while getopts d:e:s: f; do
  case "$f" in
    d) DOMAIN="$OPTARG" ;;
    e) EMAIL="$OPTARG" ;;
    s) SITE_DIR="$OPTARG" ;;
    *) usage ;;
  esac
done
[[ -n "$DOMAIN" && -n "$EMAIL" && -n "$SITE_DIR" ]] || usage

# ---------- проверки до любых изменений ----------
[[ $EUID -eq 0 ]] || die "нужен root (sudo)"
[[ "$(uname -m)" == "x86_64" ]] || die "tproxy-server ставится только на x86_64"

. /etc/os-release
case "${ID:-}" in
  ubuntu) dpkg --compare-versions "${VERSION_ID:-0}" ge 22.04 || die "нужен Ubuntu 22.04+" ;;
  debian) dpkg --compare-versions "${VERSION_ID:-0}" ge 12    || die "нужен Debian 12+" ;;
  *) die "поддерживаются только Ubuntu 22.04+ и Debian 12+" ;;
esac

[[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z0-9-]{2,}$ ]] \
  || die "домен должен быть строчным ASCII (для IDN используй xn--...)"
[[ "$EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "некорректная почта"
[[ -f "$SITE_DIR/index.html" ]] || die "в $SITE_DIR нет index.html. Нужен свой настоящий сайт, готовую заглушку использовать нельзя (это сигнатура для сканеров)"
SITE_DIR="$(realpath "$SITE_DIR")"

info "Установка зависимостей (без apt upgrade)..."
apt-get update -y
apt-get install -y --no-install-recommends git curl ca-certificates nftables dnsutils openssl iproute2

MYIP="$(curl -4fsS --max-time 10 https://api.ipify.org || true)"
[[ -n "$MYIP" ]] || die "не удалось определить внешний IPv4 сервера"
RESOLVED="$(dig +short A "$DOMAIN" | grep -E '^[0-9]+(\.[0-9]+){3}$' || true)"
grep -qx "$MYIP" <<<"$RESOLVED" \
  || die "$DOMAIN резолвится в '${RESOLVED:-ничего}', а IP сервера $MYIP. Поправь A-запись и подожди обновления DNS"

if ss -ltn '( sport = :80 or sport = :443 )' | grep -q LISTEN && ! systemctl is-active --quiet caddy; then
  die "порты 80/443 уже заняты не Caddy. Установщик tproxy-server рассчитан на чистый сервер"
fi

# ---------- секрет (стабильный между перезапусками скрипта) ----------
umask 077
if [[ ! -s "$SECRET_FILE" ]]; then
  openssl rand -hex 16 > "$SECRET_FILE"
fi
chmod 600 "$SECRET_FILE"
SECRET="$(tr -d '[:space:]' < "$SECRET_FILE")"
[[ "$SECRET" =~ ^[0-9a-f]{32}$ ]] || die "секрет в $SECRET_FILE повреждён (нужно 32 hex-символа)"
umask 022

# ---------- tproxy-server ----------
info "Загрузка tproxy-server ($REPO_REF)..."
if [[ -d "$SRC_DIR/.git" ]]; then
  git -C "$SRC_DIR" fetch --depth 1 origin "$REPO_REF"
  git -C "$SRC_DIR" checkout -q FETCH_HEAD
else
  git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$SRC_DIR"
fi
COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD)"
info "Версия tproxy-server: $COMMIT"

info "Запуск официального установщика (Caddy, MTProxy, relay, nftables)..."
echo "    Внимание: он заменит активный Caddyfile (старый будет сохранён)."
( cd "$SRC_DIR" && bash ./deploy/install.sh \
    --hostname "$DOMAIN" --email "$EMAIL" --site-dir "$SITE_DIR" --secret "$SECRET" )

# ---------- блоклист сканеров (nftables, переживает ребут) ----------
info "Настройка блоклиста сканеров..."
install -d -m 0755 /var/lib/rkn-blocklist

# Админский IP, чтобы случайно не забанить себя
ADMIN_IP="${SSH_CLIENT%% *}"
if [[ ! -f /etc/rkn-blocklist.allow ]]; then
  : > /etc/rkn-blocklist.allow
  [[ "$ADMIN_IP" =~ ^[0-9]+(\.[0-9]+){3}$ ]] && echo "$ADMIN_IP" >> /etc/rkn-blocklist.allow
fi

cat > /usr/local/sbin/rkn-blocklist-update.sh <<'UPDATE_EOF'
#!/usr/bin/env bash
# Аргумент --cached: не качать списки, взять из кэша (для загрузки системы)
set -euo pipefail
STATE=/var/lib/rkn-blocklist
CACHE="$STATE/ipv4.txt"
ALLOW=/etc/rkn-blocklist.allow
URLS=(
  https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list
  https://raw.githubusercontent.com/tread-lightly/CyberOK_Skipa_ips/refs/heads/main/lists/skipa_cidr.txt
)
EXTRA=(85.142.100.0/24 46.161.48.0/22 95.215.0.0/24 45.91.64.0/24)

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$STATE"

# Только IPv4 или IPv4/CIDR, октеты <=255, префикс 8..32 (защита от /0 и мусора)
clean() {
  sed -e 's/#.*//' -e 's/[[:space:]]//g' \
    | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$' \
    | awk -F'[./]' 'NF>=4 { ok=1; for(i=1;i<=4;i++) if($i>255) ok=0; m=(NF==5)?$5:32; if(m>32||m<8) ok=0; if(ok) print }' \
    | sort -u || true
}

if [[ "${1:-}" != "--cached" ]]; then
  : > "$T/raw"
  for u in "${URLS[@]}"; do
    curl -fsSL --retry 3 --max-time 60 "$u" >> "$T/raw" 2>/dev/null || echo "WARN: не скачался $u" >&2
    echo >> "$T/raw"
  done
  printf '%s\n' "${EXTRA[@]}" >> "$T/raw"
  clean < "$T/raw" > "$T/new"
  n=$(wc -l < "$T/new")
  # Обновляем кэш только если скачалось похоже на правду, либо кэша ещё нет
  if (( n >= 20 )) || [[ ! -s "$CACHE" ]]; then
    install -m 0644 "$T/new" "$CACHE"
  else
    echo "WARN: скачалось только $n записей, оставляю прежний кэш" >&2
  fi
fi

[[ -s "$CACHE" ]] || { echo "ОШИБКА: кэша блоклиста нет" >&2; exit 1; }
clean < "$ALLOW" > "$T/allow" 2>/dev/null || : > "$T/allow"

{
  echo "table inet rkn_block"
  echo "delete table inet rkn_block"
  echo "table inet rkn_block {"
  echo "  set rkn4 { type ipv4_addr; flags interval; auto-merge; elements = { $(paste -sd, "$CACHE") } }"
  if [[ -s "$T/allow" ]]; then
    echo "  set allow4 { type ipv4_addr; flags interval; auto-merge; elements = { $(paste -sd, "$T/allow") } }"
  else
    echo "  set allow4 { type ipv4_addr; flags interval; }"
  fi
  echo "  chain input { type filter hook input priority -10; policy accept;"
  echo "    ip saddr @allow4 accept"
  echo "    ip saddr @rkn4 drop"
  echo "  }"
  echo "}"
} > "$T/rules.nft"

# Проверка и атомарное применение: при ошибке старая таблица остаётся нетронутой
nft -c -f "$T/rules.nft"
nft -f "$T/rules.nft"
echo "Блоклист применён: $(wc -l < "$CACHE") записей"
UPDATE_EOF
chmod 0755 /usr/local/sbin/rkn-blocklist-update.sh

/usr/local/sbin/rkn-blocklist-update.sh || echo "ВНИМАНИЕ: блоклист не применился, прокси работает без него"

cat > /etc/systemd/system/rkn-blocklist.service <<'UNIT_EOF'
[Unit]
Description=Update and apply scanner blocklist (nftables)
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rkn-blocklist-update.sh
UNIT_EOF

cat > /etc/systemd/system/rkn-blocklist.timer <<'UNIT_EOF'
[Unit]
Description=Daily scanner blocklist refresh

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
UNIT_EOF

# Дистрибутивный nftables.service начинает с "flush ruleset": после старта или reload
# возвращаем нашу таблицу из кэша (без сети, чтобы не тормозить загрузку).
install -d /etc/systemd/system/nftables.service.d
cat > /etc/systemd/system/nftables.service.d/rkn-blocklist.conf <<'DROPIN_EOF'
[Service]
ExecStartPost=-/usr/local/sbin/rkn-blocklist-update.sh --cached
ExecReload=-/usr/local/sbin/rkn-blocklist-update.sh --cached
DROPIN_EOF

systemctl daemon-reload
systemctl enable --now nftables.service
systemctl enable --now rkn-blocklist.timer

# ---------- проверка результата ----------
info "Проверка..."
fail=0
curl -fsS http://127.0.0.1:8081/healthz >/dev/null && echo "  relay healthz: OK" || { echo "  relay healthz: FAIL"; fail=1; }
curl -fsS http://127.0.0.1:8081/readyz  >/dev/null && echo "  relay readyz (MTProxy): OK" || { echo "  relay readyz: FAIL"; fail=1; }

B1="$(curl -fsS --max-time 20 "https://$DOMAIN/" || true)"
B2="$(curl -fsS --max-time 20 "https://$DOMAIN/?bridge=wrong" || true)"
if [[ -n "$B1" && "$B1" == "$B2" ]]; then
  echo "  публичный сайт и ответ на неверный bridge совпадают: OK"
else
  echo "  сайт недоступен по HTTPS или ответы различаются: FAIL"; fail=1
fi

nft list set inet rkn_block rkn4 >/dev/null 2>&1 && echo "  блоклист в nftables: OK" || { echo "  блоклист в nftables: FAIL"; fail=1; }

echo
echo "=========================================================="
if (( fail )); then
  echo "Установка завершена с ошибками, смотри выше и: journalctl -u tproxy-server -u mtproxy -u caddy"
else
  echo "Готово."
fi
echo "Hostname: $DOMAIN"
echo "Secret:   $SECRET   (хранится в $SECRET_FILE)"
echo "Ссылка:   https://t.me/webproxy?server=$DOMAIN&secret=$SECRET"
echo "          tg://webproxy?server=$DOMAIN&secret=$SECRET"
echo "tproxy-server: $COMMIT"
echo "Белый список IP для блоклиста: /etc/rkn-blocklist.allow"
echo "В файрволе хостера открой только 22, 80, 443."
echo "=========================================================="
exit "$fail"
