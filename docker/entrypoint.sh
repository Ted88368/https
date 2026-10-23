#!/usr/bin/env sh
set -eu

: "${MODE:=letsencrypt}"
: "${PUBLIC_IP:=127.0.0.1}"
: "${DOMAINS:=}"
: "${SERVER_NAME:=_}"
: "${SIGN_IP:=auto}"
: "${LETSENCRYPT_STAGING:=1}"
: "${RENEW_INTERVAL_SECONDS:=21600}"
: "${PREFERRED_PROFILE:=}"
: "${ACME_EMAIL:=}"

WEBROOT=/var/www/certbot
LIVE_CERT_DIR=/etc/nginx/certs/live
LIVE_FULLCHAIN="$LIVE_CERT_DIR/fullchain.pem"
LIVE_PRIVKEY="$LIVE_CERT_DIR/privkey.pem"

PARSER="/usr/local/bin/parse-config.py"
if [ ! -f "$PARSER" ]; then
  PARSER="$(cd "$(dirname "$0")" && pwd)/parse-config.py"
fi
eval "$("$PARSER")"
export LE_LIVE_DIR

if [ "$MODE" = "letsencrypt" ] && [ "${VALID_IDENTIFIERS_COUNT:-0}" -eq 0 ]; then
  echo "Error: MODE=letsencrypt requires at least one domain (DOMAINS or SERVER_NAME) or a valid public IP (PUBLIC_IP)" >&2
  exit 1
fi
mkdir -p "$WEBROOT" "$LIVE_CERT_DIR" /run/nginx /etc/nginx/conf.d/locations

create_bootstrap_cert() {
  if [ -s "$LIVE_FULLCHAIN" ] && [ -s "$LIVE_PRIVKEY" ]; then
    return
  fi

  echo "Creating temporary self-signed certificate for $PRIMARY_NAME ($BOOTSTRAP_SAN)"
  openssl req -x509 -nodes -newkey rsa:2048 -days 2 \
    -subj "/CN=$PRIMARY_NAME" \
    -addext "subjectAltName=$BOOTSTRAP_SAN" \
    -keyout "$LIVE_PRIVKEY" \
    -out "$LIVE_FULLCHAIN"
}

render_nginx_config() {
  export FINAL_SERVER_NAMES WEBROOT LIVE_FULLCHAIN LIVE_PRIVKEY
  python3 -c '
import os, sys
template = sys.stdin.read()
res = template.replace("${SERVER_NAME}", os.environ.get("FINAL_SERVER_NAMES", "_")) \
              .replace("${WEBROOT}", os.environ.get("WEBROOT", "")) \
              .replace("${LIVE_FULLCHAIN}", os.environ.get("LIVE_FULLCHAIN", "")) \
              .replace("${LIVE_PRIVKEY}", os.environ.get("LIVE_PRIVKEY", ""))
sys.stdout.write(res)
' < /etc/nginx/templates/default.conf.template > /etc/nginx/conf.d/default.conf
}

certbot_run() {
  eval "certbot $CERTBOT_ARGS_CMD"
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
  echo "Requesting or reusing Let's Encrypt certificate for: ${PARSED_DOMAINS:-} $([ "$INCLUDE_IP" = "1" ] && echo "$PUBLIC_IP" || true)"
  if certbot_run; then
    install_issued_cert || true
  else
    echo "Certificate issuance failed; keeping current certificate and retrying later" >&2
  fi
}

renew_loop() {
  while true; do
    sleep "$RENEW_INTERVAL_SECONDS"
    echo "Running certificate renewal check"
    if certbot renew --no-random-sleep-on-renew --deploy-hook /usr/local/bin/build-fullchain.sh; then
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
