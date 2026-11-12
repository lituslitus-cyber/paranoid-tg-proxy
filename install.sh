#!/usr/bin/env bash
# WEB proxy installer for dedicated Debian/Ubuntu VPS; uses upstream tproxy-server.
# Usage: sudo bash install_paranoid_webproxy.sh [--check] [--no-blocklist]
set -Eeuo pipefail
umask 077
DOMAIN='puh.maxmir.ru'
EMAIL='lituslitus@gmail.com'
SITE='/var/www/puh.maxmir.ru'
UPSTREAM='https://github.com/telegramdesktop/tproxy-server.git'
SOURCE='/opt/tproxy-server-src'
STATE='/etc/paranoid-webproxy'
BLOCKLIST=1
CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    --no-blocklist) BLOCKLIST=0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done
say() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
on_error() { echo "ERROR at line $1, code $2; see service logs. Existing backups retained in $STATE/backups" >&2; }
trap 'on_error "$LINENO" "$?"' ERR
[[ $EUID -eq 0 ]] || die 'Run as root'
[[ $(uname -m) == x86_64 ]] || die 'Upstream MTProxy requires x86_64'
# A site is required by upstream. On fresh installs create an actual, readable,
# original static homepage rather than stopping on missing index.html.
# Existing user website files are never overwritten.
if (( ! CHECK_ONLY )) && [[ ! -f "$SITE/index.html" ]]; then
  say 'Creating original static homepage (no third-party tracking or dependencies)'
  install -d -m 0755 "$SITE"
  cat > "$SITE/index.html" <<'HTML'
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="referrer" content="no-referrer">
  <title>MaxMir — цифровые заметки</title>
  <meta name="description" content="Небольшие заметки о технологиях, организации цифровых данных и приватности.">
  <style>
    :root{color-scheme:light;--ink:#183044;--accent:#23709c;--paper:#f6f9fb}
    *{box-sizing:border-box}body{margin:0;font:17px/1.65 system-ui,-apple-system,sans-serif;color:var(--ink);background:var(--paper)}
    header,main,footer{max-width:880px;margin:auto;padding:32px 24px}
    header{padding-top:70px}h1{font-size:clamp(2rem,5vw,3.5rem);line-height:1.18;margin:0 0 16px}h2{font-size:1.3rem;margin:0 0 12px}
    .lead{font-size:1.2rem;max-width:660px;color:#405769}.panel{background:white;border:1px solid #dce5ea;border-radius:16px;padding:26px;margin:20px 0}
    a{color:var(--accent)}footer{font-size:.9rem;color:#637785}
  </style>
</head>
<body>
<header><p>MAXMIR / ЦИФРОВЫЕ ЗАМЕТКИ</p><h1>Простые технологии для повседневных задач</h1>
<p class="lead">Заметки об организации информации, надёжности сервисов и внимательном отношении к цифровым инструментам.</p></header>
<main><section class="panel"><h2>Организация цифровых данных</h2>
<p>Резервное копирование, структура папок, проверка источников и контроль версий помогают сохранять важное и упрощают работу.</p></section>
<section class="panel"><h2>Приватность и устойчивость</h2>
<p>Обновления, защищённые соединения и минимальный сбор данных полезны как для личных проектов, так и для небольших сайтов.</p></section>
<section class="panel"><h2>О сайте</h2><p>Небольшой независимый информационный проект. Здесь не используются сторонние шрифты, рекламные счётчики и cookies для отслеживания.</p></section></main>
<footer>© MaxMir · Информационные заметки</footer>
</body>
</html>
HTML
  chmod 0644 "$SITE/index.html"
fi
[[ -r "$SITE/index.html" ]] || die "Site unreadable: $SITE/index.html"
[[ "$DOMAIN" =~ ^([a-z0-9][a-z0-9-]*\.)+[a-z0-9][a-z0-9-]*$ ]] || die 'Invalid hostname'
[[ "$EMAIL" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die 'Invalid ACME email'
if (( CHECK_ONLY )); then
  say 'Systemd states'
  systemctl is-active caddy mtproxy tproxy-server tproxy-firewall || true
  say 'Listening sockets (no credentials)'
  ss -lntp '( sport = :80 or sport = :443 or sport = :8080 or sport = :8081 or sport = :2398 or sport = :8888 )' || true
  say 'Ready endpoint'
  curl -fsS --max-time 5 http://127.0.0.1:8081/readyz || true
  echo
  say 'HTTPS public site'
  curl -sS --max-time 15 -o /dev/null -w 'HTTP code: %{http_code}, TLS verify: %{ssl_verify_result}\n' "https://$DOMAIN/" || true
  say 'Firewall tables'
  nft list table inet tproxy_backend >/dev/null 2>&1 && echo 'tproxy_backend exists' || echo 'WARNING: tproxy_backend missing'
  nft list table inet paranoid_scanners >/dev/null 2>&1 && echo 'scanner table exists' || echo 'scanner table not installed'
  say 'Config summary (no secrets)'
  python3 - <<'PY' || true
import json
p='/etc/tproxy-server/config.json'
try:
 c=json.load(open(p)); print('hostname:', c.get('public_hostname')); print('base_path:', c.get('base_path')); print('listen:', c.get('listen'))
except Exception as e: print('Config not available:',type(e).__name__)
PY
  exit 0
fi
. /etc/os-release
case "$ID" in
  debian) dpkg --compare-versions "$VERSION_ID" ge 12 || die 'Debian 12+ required' ;;
  ubuntu) dpkg --compare-versions "$VERSION_ID" ge 22.04 || die 'Ubuntu 22.04+ required' ;;
  *) die 'Only Debian/Ubuntu are supported' ;;
esac
say 'Preflight: DNS and public IPv4'
command -v curl >/dev/null || { apt-get update; apt-get install -y curl ca-certificates; }
PUBLIC_IP=$(curl -4fsS --connect-timeout 5 --max-time 12 https://api.ipify.org) || die 'Cannot identify public IPv4'
[[ "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die 'Invalid public IPv4'
DNS_A=$(getent ahostsv4 "$DOMAIN" | awk '{print $1}' | sort -u) || die 'Domain DNS lookup failed'
grep -Fxq "$PUBLIC_IP" <<< "$DNS_A" || die "DNS mismatch. public=$PUBLIC_IP, DNS=$DNS_A"
[[ -z $(getent ahostsv6 "$DOMAIN" 2>/dev/null || true) ]] || echo 'WARNING: hostname has IPv6 answers. Verify IPv6 reachability separately.'
if ss -ltn '( sport = :80 or sport = :443 )' | grep -q LISTEN && ! systemctl is-active --quiet caddy; then
  die 'Port 80/443 is occupied by a service other than Caddy'
fi
say 'Install dependencies'
apt-get update
apt-get install -y --no-install-recommends git curl ca-certificates openssl nftables iproute2 python3 coreutils
install -d -m 0700 "$STATE" "$STATE/backups"
# Backup configurations before invoking the upstream installer (which replaces Caddyfile).
BACKUP="$STATE/backups/$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 0700 "$BACKUP"
for file in /etc/caddy/Caddyfile /etc/tproxy-server/config.json /etc/tproxy-server/profiles.json /etc/mtproxy/mtproxy.env /root/.tg-proxy-secret; do
  if [[ -f "$file" ]]; then install -d -m 0700 "$BACKUP$(dirname "$file")"; cp -a "$file" "$BACKUP$file"; fi
done
say 'Fetch latest upstream source'
if [[ -d "$SOURCE/.git" ]]; then
  git -C "$SOURCE" fetch --depth 1 origin master
  git -C "$SOURCE" checkout --detach -q FETCH_HEAD
else
  [[ ! -e "$SOURCE" ]] || die "$SOURCE exists but is not a Git checkout"
  git clone --depth 1 --branch master "$UPSTREAM" "$SOURCE"
fi
COMMIT=$(git -C "$SOURCE" rev-parse HEAD)
echo "Upstream commit: $COMMIT"
# Ensure upstream installer supports path-bound client links and NAT handling.
grep -Fq -- '--base-path' "$SOURCE/deploy/install.sh" || die 'Upstream installer missing --base-path'
grep -Fq -- 'MTPROXY_NAT_ARGS' "$SOURCE/deploy/install.sh" || die 'Upstream installer missing NAT handling'
# Keep the existing path, but rotate compromised credentials from shared logs.
# A new prefix is generated only for a fresh deployment.
if [[ -f /etc/tproxy-server/config.json ]]; then
  BASE_PATH=$(python3 - <<'PY'
import json
print(json.load(open('/etc/tproxy-server/config.json')).get('base_path',''))
PY
)
  [[ -n "$BASE_PATH" ]] || die 'Existing root-path deployment: refusing to silently migrate; review manually'
else
  BASE_PATH=$(head -c 10 /dev/urandom | base32 | tr 'A-Z' 'a-z')
fi
[[ "$BASE_PATH" =~ ^[a-zA-Z0-9][a-zA-Z0-9_/-]*$ && ${#BASE_PATH} -le 128 ]] || die 'Invalid base_path'
SECRET=$(openssl rand -hex 16)
# Preserve a new secret across failed retries only if the first attempt has written it.
# This invocation deliberately rotates the existing credential.
say 'Install upstream WEB relay + internal MTProxy + Caddy (rotating leaked secret)'
# Upstream prints secrets; capture output in a root-only file, not the terminal transcript.
UPLOG="$STATE/upstream-install.log"
if ! ( cd "$SOURCE" && bash ./deploy/install.sh --hostname "$DOMAIN" --email "$EMAIL" --site-dir "$SITE" --base-path "$BASE_PATH" --static-routes exact --secret "$SECRET" ) > "$UPLOG" 2>&1; then
  echo "Upstream installation failed. Root-only log: $UPLOG" >&2
  sed -E 's/(secret|Secret|Proxy link|Proxy secret|mtproxy secret):.*/\1: [REDACTED]/' "$UPLOG" | tail -n 24 >&2
  exit 1
fi
chmod 0600 "$UPLOG"
# Legacy blocklist from paranoid-tg-proxy v2 includes input drops and can block
# legitimate clients with dynamic IPs, including on SSH. Remove it after upstream
# has successfully started, leaving its config files intact for audit.
if [[ -f /usr/local/sbin/rkn-blocklist-update.sh ]]; then
  systemctl disable --now rkn-blocklist.timer rkn-blocklist.service 2>/dev/null || true
  if [[ -f /etc/systemd/system/nftables.service.d/rkn-blocklist.conf ]]; then
    mv /etc/systemd/system/nftables.service.d/rkn-blocklist.conf "$BACKUP/rkn-blocklist.conf"
    systemctl daemon-reload
  fi
  nft delete table inet rkn_block 2>/dev/null || true
fi
# Backstop upstream-generated link format: 0x70 prefix + hex-decoded 16-byte secret.
install -m 0600 /dev/null "$STATE/client-link.txt"
export DOMAIN BASE_PATH SECRET
python3 - <<'PY' > "$STATE/client-link.txt"
import os,base64,urllib.parse
secret=bytes.fromhex(os.environ['SECRET'])
marked=base64.urlsafe_b64encode(b'\x70'+secret).decode().rstrip('=')
server=os.environ['DOMAIN']+'/'+os.environ['BASE_PATH']
print('https://t.me/webproxy?'+urllib.parse.urlencode({'server':server,'secret':marked}))
print('tg://webproxy?'+urllib.parse.urlencode({'server':server,'secret':marked}))
PY
chmod 0600 "$STATE/client-link.txt"
# Scanner blocking only on the public WEB port. Keep SSH always accessible.
# Do not load untrusted third-party blocklists into SSH/global firewall rules.
if (( BLOCKLIST )); then
  say 'Install optional scanner blocklist for TCP 443 only'
  cat > /usr/local/sbin/paranoid-scanner-update <<'UPDATE'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
F=/var/lib/paranoid-webproxy/scanner4.txt
install -d -m 0700 /var/lib/paranoid-webproxy
TMP=$(mktemp); RULES=$(mktemp); trap 'rm -f "$TMP" "$RULES"' EXIT
# HTTPS-only source. On download failure, leave the existing rules untouched.
curl --fail --silent --show-error --location --max-time 25 --retry 2 \
  'https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list' > "$TMP"
python3 - "$TMP" "$RULES" <<'PY'
import sys,ipaddress
values=set()
for line in open(sys.argv[1]):
 line=line.split('#',1)[0].strip()
 if not line:continue
 try:
  net=ipaddress.ip_network(line,strict=False)
  if net.version==4 and net.prefixlen >= 16:values.add(str(net))
 except ValueError:pass
if len(values)<20:raise SystemExit('blocklist too short; refusing update')
with open(sys.argv[2],'w') as f:
 f.write('add table inet paranoid_scanners\n')
 f.write('add set inet paranoid_scanners scanner4 { type ipv4_addr; flags interval; auto-merge; }\n')
 f.write('add chain inet paranoid_scanners input { type filter hook input priority -20; policy accept; }\n')
 f.write('flush chain inet paranoid_scanners input\n')
 f.write('flush set inet paranoid_scanners scanner4\n')
 for i in sorted(values):f.write('add element inet paranoid_scanners scanner4 { '+i+' }\n')
 f.write('add rule inet paranoid_scanners input tcp dport 443 ip saddr @scanner4 drop\n')
PY
# Create table/chain/set idempotently, then replace the data in one nft batch.
nft add table inet paranoid_scanners 2>/dev/null || true
nft list set inet paranoid_scanners scanner4 >/dev/null 2>&1 || \
  nft 'add set inet paranoid_scanners scanner4 { type ipv4_addr; flags interval; auto-merge; }'
nft list chain inet paranoid_scanners input >/dev/null 2>&1 || \
  nft 'add chain inet paranoid_scanners input { type filter hook input priority -20; policy accept; }'
sed -i '1,3d' "$RULES"
nft -c -f "$RULES"
nft -f "$RULES"
install -m 0600 "$TMP" "$F"
echo 'scanner rules updated; SSH and port 80 unaffected'
UPDATE
  chmod 0755 /usr/local/sbin/paranoid-scanner-update
  cat > /etc/systemd/system/paranoid-scanner-update.service <<'UNIT'
[Unit]
Description=Refresh optional TCP 443 scanner filters
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/paranoid-scanner-update
[Install]
WantedBy=multi-user.target
UNIT
  cat > /etc/systemd/system/paranoid-scanner-update.timer <<'UNIT'
[Unit]
Description=Refresh optional scanner filters daily
[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now paranoid-scanner-update.timer
  systemctl enable paranoid-scanner-update.service
  if ! /usr/local/sbin/paranoid-scanner-update; then
    echo 'WARNING: scanner list could not be installed; proxy remains usable.' >&2
  fi
fi
say 'Post-install sanity checks'
systemctl is-active --quiet caddy || die 'Caddy is not active'
systemctl is-active --quiet mtproxy || die 'MTProxy backend is not active'
systemctl is-active --quiet tproxy-server || die 'WEB relay is not active'
curl -fsS --max-time 10 http://127.0.0.1:8081/readyz >/dev/null || die 'WEB relay not ready'
curl -fsS --max-time 20 "https://$DOMAIN/" >/dev/null || die 'Public HTTPS site unavailable'
# Test the authenticated path-bound bridge, not only the public site.
BRIDGE=$(python3 - <<'BRIDGEPY'
import os,hmac,hashlib,base64
msg=('tdesktop-web-proxy-bridge-v2\n'+os.environ['DOMAIN']+'\n'+os.environ['BASE_PATH']).encode()
print(base64.urlsafe_b64encode(hmac.new(bytes.fromhex(os.environ['SECRET']),msg,hashlib.sha256).digest()).decode().rstrip('='))
BRIDGEPY
)
if ! curl -fsS --max-time 20 "https://$DOMAIN/$BASE_PATH/?bridge=$BRIDGE" | grep -q 'tproxy-init'; then
  die 'Authenticated WEB bridge failed; verify Caddy, secret and base_path'
fi
nft list table inet tproxy_backend >/dev/null || die 'MTProxy backend firewall table missing'
# Read private URL as root only; do not print secret into installation logs.
echo "SUCCESS: services and HTTPS respond. Link saved to $STATE/client-link.txt (root-only)."
echo 'To show link: sudo cat /etc/paranoid-webproxy/client-link.txt'
echo 'To recheck: sudo bash install_paranoid_webproxy.sh --check'
echo 'NOTE: Only a WEB-proxy-capable Telegram client can use this link. No blocking immunity is possible.'
