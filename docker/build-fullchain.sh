#!/usr/bin/env sh
# 用 Let's Encrypt 签发的最新证书重建 nginx 使用的 fullchain.pem。
# Let's Encrypt shortlived(IP)证书的 fullchain.pem 末尾会多带一张根证书
# （ISRG Root X2 交叉签/自签副本），部分客户端会判“不安全”。
# 这里只保留 叶子证书 + 中间证书，链到浏览器信任库中的真实 ISRG 根。
set -e

CERTS_DIR="/etc/nginx/certs/live"
DST="$CERTS_DIR/fullchain.pem"
DST_KEY="$CERTS_DIR/privkey.pem"

# 注意：certbot 的 lineage 目录名形如 ip-<IP>-prod / ip-<IP>-staging，
# 用的是连字符 "-prod"，不是点 ".prod"。
CAND=""
for d in /etc/letsencrypt/live/ip-*-prod /etc/letsencrypt/live/ip-*-staging; do
  [ -s "$d/fullchain.pem" ] && [ -s "$d/privkey.pem" ] && CAND="$d" && break
done

if [ -z "$CAND" ]; then
  echo "no letsencrypt cert found, keeping current fullchain" >&2
  exit 0
fi

SRC="$CAND/fullchain.pem"
SRC_KEY="$CAND/privkey.pem"

# 统计证书块数量；若超过 3 张，则丢弃最后一张（即末尾多余的根证书）。
awk '
/BEGIN CERTIFICATE/ { n++ }
{ lines[cnt++] = $0 }
END {
  total = 0
  for (i = 0; i < cnt; i++) if (lines[i] ~ /BEGIN CERTIFICATE/) total++
  cur = 0
  for (i = 0; i < cnt; i++) {
    if (lines[i] ~ /BEGIN CERTIFICATE/) cur++
    if (total > 3) { if (cur < total) print lines[i] }
    else { print lines[i] }
  }
}' "$SRC" > "$DST"

cp "$SRC_KEY" "$DST_KEY"
chmod 600 "$DST_KEY"
