#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="https-ip"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="/opt/${APP_NAME}"
CONFIG_DIR="/etc/${APP_NAME}"
WEBROOT="/var/www/${APP_NAME}/certbot"
HTML_DIR="/var/www/${APP_NAME}/html"
CERT_DIR="${CONFIG_DIR}/certs"
ENV_FILE="${CONFIG_DIR}/environment"
CERTBOT_VENV="${APP_DIR}/venv"

# Read simple KEY=value settings used by the native installer.
DOTENV_FILE="${SCRIPT_DIR}/.env"
if [[ -f "$DOTENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$DOTENV_FILE"
  set +a
fi

: "${MODE:=selfsigned}"
: "${PUBLIC_IP:=127.0.0.1}"
: "${LETSENCRYPT_STAGING:=0}"
: "${ACME_EMAIL:=}"
: "${SERVER_NAME:=_}"
: "${PROXY_LOCATION:=/}"
: "${PROXY_PASS:=}"

die() { printf '错误: %s\n' "$*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }

[[ "$(id -u)" -eq 0 ]] || die "请使用 root 运行，例如: sudo -E ./install.sh"
[[ -f /etc/os-release ]] || die "无法识别操作系统"
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "此脚本只支持 Ubuntu"
command -v systemctl >/dev/null || die "系统缺少 systemd"

if [[ "$MODE" != selfsigned && "$MODE" != letsencrypt ]]; then
  die "MODE 只能是 selfsigned 或 letsencrypt"
fi
if [[ "$MODE" == letsencrypt && ! "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && ! "$PUBLIC_IP" =~ : ]]; then
  die "PUBLIC_IP 必须是公网 IPv4 或 IPv6 地址"
fi
[[ "$SERVER_NAME" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "SERVER_NAME 包含不支持的字符"
SERVER_NAMES="$SERVER_NAME"
if [[ "$SERVER_NAME" == "_" ]]; then
  SERVER_NAMES="$PUBLIC_IP"
elif [[ "$SERVER_NAME" != "$PUBLIC_IP" ]]; then
  SERVER_NAMES="$SERVER_NAME $PUBLIC_IP"
fi
cd "$SCRIPT_DIR"

log "安装系统依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends nginx openssl ca-certificates python3 python3-venv

log "准备服务目录"
install -d -m 0755 "$APP_DIR" "$CONFIG_DIR" "$WEBROOT" "$HTML_DIR" "$CERT_DIR" "$HTML_DIR/downloads"
install -m 0644 "$SCRIPT_DIR/public/index.html" "$HTML_DIR/index.html"
if [[ -d "$SCRIPT_DIR/public/downloads" ]]; then
  cp -r "$SCRIPT_DIR/public/downloads/". "$HTML_DIR/downloads/" 2>/dev/null || true
fi
python3 -m venv "$CERTBOT_VENV"
"$CERTBOT_VENV/bin/pip" install --upgrade "certbot>=5.4"

printf 'MODE=%q\nPUBLIC_IP=%q\nLETSENCRYPT_STAGING=%q\nACME_EMAIL=%q\nSERVER_NAME=%q\nPROXY_LOCATION=%q\nPROXY_PASS=%q\n' \
  "$MODE" "$PUBLIC_IP" "$LETSENCRYPT_STAGING" "$ACME_EMAIL" "$SERVER_NAME" "$PROXY_LOCATION" "$PROXY_PASS" > "$ENV_FILE"
chmod 0600 "$ENV_FILE"

log "生成 Nginx 配置"
if [[ -n "$PROXY_PASS" ]]; then
  LOC="${PROXY_LOCATION:-/}"
  LOCATION_MAIN="    location ${LOC} {
        proxy_pass ${PROXY_PASS};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }"
  if [[ "$LOC" != "/" ]]; then
    LOCATION_MAIN="${LOCATION_MAIN}

    location / { try_files \$uri \$uri/ /index.html; }"
  fi
else
  LOCATION_MAIN="    location / { try_files \$uri \$uri/ /index.html; }"
fi

cat > /etc/nginx/sites-available/${APP_NAME}.conf <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${SERVER_NAMES};

    location /.well-known/acme-challenge/ {
        root ${WEBROOT};
        default_type text/plain;
    }
    location / {
        proxy_pass http://host.docker.internal:19090/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name ${SERVER_NAMES};
    ssl_certificate ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    root ${HTML_DIR};
    index index.html;
    location /downloads/ {
        alias ${HTML_DIR}/downloads/;
        autoindex on;
        autoindex_exact_size off;
        autoindex_localtime on;
        charset utf-8;
    }
${LOCATION_MAIN}
}
EOF
# Ubuntu enables its sample site by default. If it remains enabled, requests
# can be handled by that site instead of this certificate configuration.
rm -f /etc/nginx/sites-enabled/default
ln -sfn /etc/nginx/sites-available/${APP_NAME}.conf /etc/nginx/sites-enabled/${APP_NAME}.conf

if [[ ! -s "$CERT_DIR/fullchain.pem" || ! -s "$CERT_DIR/privkey.pem" ]]; then
  log "生成临时自签名证书"
  openssl req -x509 -nodes -newkey rsa:2048 -days 2 \
    -subj "/CN=${PUBLIC_IP}" -addext "subjectAltName=IP:${PUBLIC_IP}" \
    -keyout "$CERT_DIR/privkey.pem" -out "$CERT_DIR/fullchain.pem" >/dev/null 2>&1
  chmod 0600 "$CERT_DIR/privkey.pem"
fi

cat > "$APP_DIR/renew-cert.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/https-ip/environment
WEBROOT=/var/www/https-ip/certbot
CERT_DIR=/etc/https-ip/certs
VENV=/opt/https-ip/venv/bin/certbot

install_current() {
  suffix="prod"
  [[ "$LETSENCRYPT_STAGING" == "1" ]] && suffix="staging"
  name="ip-${PUBLIC_IP//:/-}-${suffix}"
  live="/etc/letsencrypt/live/${name}"
  install -m 0644 "$live/fullchain.pem" "$CERT_DIR/fullchain.pem"
  install -m 0600 "$live/privkey.pem" "$CERT_DIR/privkey.pem"
  nginx -t
  systemctl reload nginx
}

if [[ "${1:-}" == "--install-only" ]]; then
  install_current
  exit 0
fi

if [[ "$MODE" == "letsencrypt" ]]; then
  suffix="prod"
  [[ "$LETSENCRYPT_STAGING" == "1" ]] && suffix="staging"
  name="ip-${PUBLIC_IP//:/-}-${suffix}"
  args=(certonly --webroot --webroot-path "$WEBROOT" --ip-address "$PUBLIC_IP"
    --cert-name "$name" --preferred-profile shortlived --agree-tos
    --non-interactive --keep-until-expiring)
  [[ -n "$ACME_EMAIL" ]] && args+=(--email "$ACME_EMAIL") || args+=(--register-unsafely-without-email)
  [[ "$LETSENCRYPT_STAGING" == "1" ]] && args+=(--staging)
  "$VENV" "${args[@]}"
  "$APP_DIR/renew-cert.sh" --install-only
  "$VENV" renew --quiet --deploy-hook "/opt/https-ip/renew-cert.sh --install-only"
fi
EOF
chmod 0700 "$APP_DIR/renew-cert.sh"

cat > /etc/systemd/system/${APP_NAME}-renew.service <<EOF
[Unit]
Description=Renew ${APP_NAME} Let's Encrypt certificate
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${APP_DIR}/renew-cert.sh
EOF
cat > /etc/systemd/system/${APP_NAME}-renew.timer <<EOF
[Unit]
Description=Run ${APP_NAME} certificate renewal

[Timer]
OnBootSec=10min
OnUnitActiveSec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF

log "校验并启动 Nginx"
nginx -t
systemctl daemon-reload
systemctl enable --now nginx

if [[ "$MODE" == "letsencrypt" ]]; then
  log "申请或复用 Let's Encrypt IP 证书"
  if ! "$APP_DIR/renew-cert.sh"; then
    printf "错误: Let's Encrypt 证书申请失败，当前仍使用临时自签名证书。\n" >&2
    printf '请确认公网 TCP 80/443 可访问、PUBLIC_IP 正确，然后查看: journalctl -u %s-renew.service\n' "$APP_NAME" >&2
    exit 1
  fi
  systemctl enable --now ${APP_NAME}-renew.timer
else
  systemctl disable --now ${APP_NAME}-renew.timer 2>/dev/null || true
fi

systemctl reload nginx
if [[ "$MODE" == "selfsigned" ]]; then
  printf '\n安装完成: https://%s/（当前为自签名证书，浏览器会显示不安全）\n' "$PUBLIC_IP"
else
  printf '\n安装完成: https://%s/\n' "$PUBLIC_IP"
fi
printf '状态: systemctl status nginx %s-renew.timer\n' "$APP_NAME"
