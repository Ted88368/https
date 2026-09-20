#!/usr/bin/env sh
set -eu

: "${MODE:=letsencrypt}"
: "${PUBLIC_IP:=127.0.0.1}"
: "${LETSENCRYPT_STAGING:=1}"
: "${RENEW_INTERVAL_SECONDS:=21600}"
: "${SERVER_NAME:=_}"

WEBROOT=/var/www/certbot
LIVE_CERT_DIR=/etc/nginx/certs/live
LIVE_FULLCHAIN="$LIVE_CERT_DIR/fullchain.pem"
LIVE_PRIVKEY="$LIVE_CERT_DIR/privkey.pem"

if [ "$MODE" = "letsencrypt" ] && [ -z "${PUBLIC_IP:-}" ]; then
  echo "PUBLIC_IP is required when MODE=letsencrypt" >&2
  exit 1
fi

if [ "$LETSENCRYPT_STAGING" = "1" ]; then
  CERT_NAME="ip-$PUBLIC_IP-staging"
else
  CERT_NAME="ip-$PUBLIC_IP-prod"
fi
LE_LIVE_DIR="/etc/letsencrypt/live/$CERT_NAME"

mkdir -p "$WEBROOT" "$LIVE_CERT_DIR" /run/nginx /etc/nginx/conf.d/locations

create_bootstrap_cert() {
  if [ -s "$LIVE_FULLCHAIN" ] && [ -s "$LIVE_PRIVKEY" ]; then
    return
  fi

  echo "Creating temporary self-signed certificate for $PUBLIC_IP"
  openssl req -x509 -nodes -newkey rsa:2048 -days 2 \
    -subj "/CN=$PUBLIC_IP" \
    -addext "subjectAltName=IP:$PUBLIC_IP" \
    -keyout "$LIVE_PRIVKEY" \
    -out "$LIVE_FULLCHAIN"
}

render_nginx_config() {
  export SERVER_NAME WEBROOT LIVE_FULLCHAIN LIVE_PRIVKEY
  python3 -c '
import os, sys
template = sys.stdin.read()
res = template.replace("${SERVER_NAME}", os.environ.get("SERVER_NAME", "_")) \
              .replace("${WEBROOT}", os.environ.get("WEBROOT", "")) \
              .replace("${LIVE_FULLCHAIN}", os.environ.get("LIVE_FULLCHAIN", "")) \
              .replace("${LIVE_PRIVKEY}", os.environ.get("LIVE_PRIVKEY", ""))
sys.stdout.write(res)
' < /etc/nginx/templates/default.conf.template > /etc/nginx/conf.d/default.conf
}

certbot_args() {
  args="certonly --webroot --webroot-path $WEBROOT --ip-address $PUBLIC_IP --cert-name $CERT_NAME --preferred-profile shortlived --agree-tos --non-interactive --keep-until-expiring"

  if [ "$LETSENCRYPT_STAGING" = "1" ]; then
    args="$args --staging"
  fi

  if [ -n "${ACME_EMAIL:-}" ]; then
    args="$args --email $ACME_EMAIL"
  else
    args="$args --register-unsafely-without-email"
  fi

  printf '%s\n' "$args"
}

# 用 Let's Encrypt 下发的最新证书重建完整链（叶子 + 中间证书），
# 并去掉链末尾多余的根证书，避免含不被信任根导致“不安全”。
build_fullchain() {
  /usr/local/bin/build-fullchain.sh
}

install_issued_cert() {
  if [ ! -s "$LE_LIVE_DIR/fullchain.pem" ] || [ ! -s "$LE_LIVE_DIR/privkey.pem" ]; then
    return 1
  fi

  build_fullchain
  nginx -s reload || true
}

issue_or_reuse_cert() {
  echo "Requesting or reusing Let's Encrypt IP certificate for $PUBLIC_IP"
  # shellcheck disable=SC2046
  if certbot $(certbot_args); then
    install_issued_cert || true
  else
    echo "Certificate issuance failed; keeping current certificate and retrying later" >&2
  fi
}

renew_loop() {
  while true; do
    sleep "$RENEW_INTERVAL_SECONDS"
    echo "Running certificate renewal check"
    if certbot renew --webroot --webroot-path "$WEBROOT" --deploy-hook "/usr/local/bin/build-fullchain.sh; nginx -s reload"; then
      install_issued_cert || true
    else
      echo "Certificate renewal check failed" >&2
    fi
  done
}

create_bootstrap_cert
render_nginx_config

nginx -g "daemon off;" &
NGINX_PID=$!

if [ "$MODE" = "letsencrypt" ]; then
  issue_or_reuse_cert
  renew_loop &
else
  echo "Running with self-signed certificate only; Certbot is disabled"
fi

wait "$NGINX_PID"
