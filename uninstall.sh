#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$(id -u)" -eq 0 ]] || { echo "请使用 root 运行" >&2; exit 1; }
systemctl disable --now https-ip-renew.timer 2>/dev/null || true
rm -f /etc/nginx/sites-enabled/https-ip.conf /etc/nginx/sites-available/https-ip.conf
rm -f /etc/systemd/system/https-ip-renew.service /etc/systemd/system/https-ip-renew.timer
systemctl daemon-reload
rm -rf /opt/https-ip /etc/https-ip /var/www/https-ip
systemctl reload nginx 2>/dev/null || true
echo "已卸载 https-ip；未删除 Nginx、Certbot 或 /etc/letsencrypt 中的其他证书。"
