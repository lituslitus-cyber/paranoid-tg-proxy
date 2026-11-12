#!/usr/bin/env bash
# Cleanup dedicated VPS proxy deployment. Keeps SSH, OS packages, other firewall tables and git checkout.
# Usage: sudo bash cleanup_paranoid_proxy.sh --apply
set -Eeuo pipefail
if [[ ${1:-} != '--apply' ]]; then
  echo 'This removes Caddy/MTProxy/tproxy-server proxy configs and the named nftables tables.'
  echo 'Keeps SSH, package installations, original Git checkout, and web root.'
  echo 'Creates protected backup /root/proxy-backup-YYYYMMDD-HHMMSS.tar.gz.'
  echo 'Run: sudo bash cleanup_paranoid_proxy.sh --apply'
  exit 0
fi
[[ $EUID -eq 0 ]] || { echo 'Run as root' >&2; exit 1; }
umask 077
BACKUP="/root/proxy-backup-$(date -u +%Y%m%d-%H%M%S).tar.gz"
paths=(/etc/caddy /etc/tproxy-server /etc/mtproxy /etc/paranoid-webproxy /etc/rkn-blocklist.allow /var/lib/rkn-blocklist /var/lib/paranoid-webproxy /root/.tg-proxy-secret /etc/systemd/system/tproxy-server.service /etc/systemd/system/mtproxy.service /etc/systemd/system/tproxy-firewall.service /etc/systemd/system/rkn-blocklist.service /etc/systemd/system/rkn-blocklist.timer /etc/systemd/system/paranoid-scanner-update.service /etc/systemd/system/paranoid-scanner-update.timer /etc/systemd/system/nftables.service.d/rkn-blocklist.conf /etc/systemd/system/caddy.service.d)
existing=()
for p in "${paths[@]}"; do [[ ! -e "$p" ]] || existing+=("${p#/}"); done
if ((${#existing[@]})); then tar -C / -czf "$BACKUP" "${existing[@]}"; else touch "$BACKUP"; fi
chmod 600 "$BACKUP"
printf 'Private backup: %s\n' "$BACKUP"
for u in rkn-blocklist.timer paranoid-scanner-update.timer rkn-blocklist.service paranoid-scanner-update.service tproxy-firewall.service tproxy-server.service mtproxy.service caddy.service; do
  systemctl disable --now "$u" >/dev/null 2>&1 || true
done
for t in tproxy_backend rkn_block paranoid_scanners; do
  nft delete table inet "$t" 2>/dev/null || true
done
rm -f /etc/systemd/system/tproxy-server.service /etc/systemd/system/mtproxy.service /etc/systemd/system/tproxy-firewall.service /etc/systemd/system/rkn-blocklist.service /etc/systemd/system/rkn-blocklist.timer /etc/systemd/system/paranoid-scanner-update.service /etc/systemd/system/paranoid-scanner-update.timer /etc/systemd/system/nftables.service.d/rkn-blocklist.conf
rm -f /usr/local/sbin/rkn-blocklist-update.sh /usr/local/sbin/paranoid-scanner-update /usr/local/bin/tproxy-server /usr/local/bin/mtproxy
rm -rf /etc/tproxy-server /etc/mtproxy /etc/paranoid-webproxy /var/lib/rkn-blocklist /var/lib/paranoid-webproxy /opt/tproxy-server-src
rm -f /etc/rkn-blocklist.allow /root/.tg-proxy-secret
# Keep /etc/caddy directory and binary; remove only proxy Caddyfile (backup exists).
rm -f /etc/caddy/Caddyfile
systemctl daemon-reload
printf '\nCleaned proxy deployment. SSH/firewall defaults and %s remain untouched.\n' '/var/www/puh.maxmir.ru'
printf 'Check: systemctl is-active caddy tproxy-server mtproxy; sudo nft list tables\n'
printf 'Backup may contain secrets. Do not publish it.\n'
