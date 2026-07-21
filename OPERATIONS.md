# 运维文档

## 1. 服务概览

本服务通过 Docker Compose 运行一个 Nginx HTTPS 服务：

- TCP `80`：提供 ACME HTTP-01 校验，并将普通请求重定向到 HTTPS。
- TCP `443`：提供静态页面、文件下载服务（`/downloads/`）和 HTTPS 访问。
- Certbot：在 `MODE=letsencrypt` 时申请、复用和续签 Let's Encrypt IP 地址证书。
- `letsencrypt` 卷：保存 Certbot 账号、订单和证书数据。
- `nginx-certs` 卷：保存 Nginx 当前实际加载的证书和私钥。

容器名为 `https-ip`，服务名为 `https-ip`。默认每 6 小时检查一次证书续签。

## 2. 上线前检查

上线主机需要安装并运行 Docker Engine 和 Docker Compose Plugin。正式签发证书前确认：

1. 主机拥有公网 IPv4 或 IPv6，且 `PUBLIC_IP` 与外部实际访问的地址一致。
2. 云安全组、主机防火墙和上游 NAT 已放行 TCP `80`、`443`。
3. `80`、`443` 未被其他进程占用。
4. 服务器时间准确，能够访问 Let's Encrypt ACME 服务。
5. 已准备好证书通知邮箱 `ACME_EMAIL`。

检查端口占用：

```bash
sudo ss -ltnp | grep -E ':(80|443)\b'
```

## 3. 部署

### 3.1 首次部署

```bash
git clone <repository-url>
cd https
cp .env.example .env
vi .env
```

先使用自签名模式验证容器和网络链路：

```env
MODE=selfsigned
PUBLIC_IP=服务器实际访问地址
```

启动并确认状态：

```bash
docker compose up -d --build
docker compose ps
docker compose logs --tail=100 https-ip
curl -kI https://服务器实际访问地址/
```

### 3.2 申请正式证书

公网环境建议先使用 staging：

```env
MODE=letsencrypt
PUBLIC_IP=公网IP
ACME_EMAIL=运维邮箱
LETSENCRYPT_STAGING=1
RENEW_INTERVAL_SECONDS=21600
SERVER_NAME=_
```

```bash
docker compose up -d --build
docker compose logs -f https-ip
```

确认日志显示证书申请成功、外部能够访问 `80` 和 `443` 后，再切换正式环境：

```env
LETSENCRYPT_STAGING=0
```

```bash
docker compose up -d --force-recreate
```

staging 和正式环境使用不同的证书名称，正式切换不会复用 staging 证书。

## 4. 日常巡检

建议每天至少检查一次容器、端口和证书有效期：

```bash
docker compose ps
docker inspect -f '{{.State.Status}} {{.State.Restarting}}' https-ip
curl -fsSI https://公网IP/ >/dev/null && echo HTTPS_OK
openssl s_client -connect 公网IP:443 -showcerts </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

重点关注：

- 容器状态应为 `Up`，且不应持续重启。
- HTTPS 请求应返回 `2xx` 或预期的 `3xx`。
- 证书的 `notAfter` 应覆盖业务需要；IP 证书有效期较短，不能仅依赖人工续签。
- 日志中不应持续出现 `Certificate issuance failed` 或 `Certificate renewal check failed`。

查看最近日志：

```bash
docker compose logs --since=24h --timestamps https-ip
```

当前 Compose 配置没有 Docker healthcheck，也没有将 Nginx 日志持久化到宿主机。生产环境应使用外部监控定时探测 HTTPS，并配置 Docker 日志轮转。

## 5. 配置变更

修改 `.env` 后重建或重新创建容器：

```bash
docker compose config
docker compose up -d --build --force-recreate
docker compose ps
```

修改页面 `public/index.html` 或 Nginx 模板后必须重新构建镜像。不要删除 `letsencrypt` 和 `nginx-certs` 卷，否则会丢失 Certbot 状态和当前证书。

### 5.1 Nginx 反向代理

服务支持开箱即用的配置化反向代理。只需在 `.env` 或环境变量中增加 `PROXY_PASS` 变量：

```env
PROXY_PASS=http://127.0.0.1:8080
```

对于后端目标服务地址 `PROXY_PASS`：
- **后端是同一个 Compose 项目中的服务**：使用 Compose 服务名，例如 `PROXY_PASS=http://backend:8080`。
- **后端运行在另一台机器**：使用该机器在网络中可达的内网/公网地址，例如 `PROXY_PASS=http://10.0.0.20:8080`，并确认防火墙放行后端端口。
- **后端运行在宿主机**：Docker 环境可在 `https-ip` 服务中增加 `extra_hosts: ["host.docker.internal:host-gateway"]`，然后配置 `PROXY_PASS=http://host.docker.internal:8080`；Ubuntu 原生部署直接配置 `PROXY_PASS=http://127.0.0.1:8080`。

配置 `PROXY_PASS` 后，自动注入了标准的 HTTP / WebSocket 请求头代理配置（`Host`, `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`, `Upgrade`, `Connection`）。同时保持 `/downloads/` 目录和 ACME 校验路径不受影响。

如果需要更复杂的反向代理规则（例如定制超时时间、多条 location 等），可手动编辑 `docker/nginx.conf.template`（Docker 部署）或 `/etc/nginx/sites-available/https-ip.conf`（Ubuntu 原生部署）。

修改配置后应用生效并检查：

```bash
docker compose up -d --build --force-recreate
docker compose exec https-ip nginx -t
docker compose logs --tail=100 https-ip
curl -fsSI https://公网IP/
```

不要删除 80 端口服务中的以下 ACME challenge 配置，否则后续证书申请和续签可能失败：

```nginx
location /.well-known/acme-challenge/ {
    root ${WEBROOT};
    default_type text/plain;
}
```

## 6. 证书续签

容器启动时会尝试申请或复用证书；之后后台按 `RENEW_INTERVAL_SECONDS` 执行 `certbot renew`。续签成功后会复制证书到 Nginx 目录并 reload Nginx。

检查续签相关日志：

```bash
docker compose logs --since=12h https-ip | grep -E 'certificate|renew|Certbot|certbot'
```

续签失败时，先确认：

1. 公网 `80` 仍然可以访问 ACME challenge 路径。
2. `PUBLIC_IP` 没有变化，且 DNS/NAT/安全组配置正确。
3. 容器可以访问外网和 Let's Encrypt。
4. 没有因为频繁申请触发速率限制。

修复网络或配置后可重新创建容器触发启动申请：

```bash
docker compose up -d --force-recreate
docker compose logs -f https-ip
```

不要通过删除证书卷来“强制续签”，这会破坏账号和订单状态并增加触发限制的风险。

## 7. 备份与恢复

至少备份两个命名卷。备份前暂停服务可以保证文件状态一致：

```bash
mkdir -p backups
docker compose stop
docker run --rm \
  -v https_letsencrypt:/data:ro \
  -v "$PWD/backups":/backup \
  alpine:3.20 tar czf /backup/letsencrypt-$(date +%Y%m%d%H%M%S).tgz -C /data .
docker run --rm \
  -v https_nginx-certs:/data:ro \
  -v "$PWD/backups":/backup \
  alpine:3.20 tar czf /backup/nginx-certs-$(date +%Y%m%d%H%M%S).tgz -C /data .
docker compose start
```

实际卷名以 `docker volume ls` 为准；Compose 默认会在项目名前加前缀：

```bash
docker volume ls | grep -E 'letsencrypt|nginx-certs'
```

恢复前停止服务，并将备份解压回对应卷。恢复完成后启动服务并检查证书：

```bash
docker compose stop
docker compose start
docker compose ps
```

备份文件包含私钥，应限制访问权限并存放到受控位置：

```bash
chmod 600 backups/*
```

## 8. 升级与回滚

升级前先保存当前版本和配置：

```bash
git rev-parse HEAD
cp .env .env.backup.$(date +%Y%m%d%H%M%S)
docker compose config > compose.config.backup.yml
```

部署新版本：

```bash
git pull --ff-only
docker compose build --pull
docker compose up -d --force-recreate
docker compose ps
curl -fsSI https://公网IP/
```

若新版本异常，切回已验证的代码版本后重新构建并启动：

```bash
git checkout <known-good-commit>
docker compose up -d --build --force-recreate
docker compose logs --tail=100 https-ip
```

不要执行 `docker compose down -v`，除非已确认不再需要现有证书和 ACME 数据。

## 9. 故障排查

### 容器无法启动

```bash
docker compose ps
docker compose logs --tail=200 https-ip
docker compose config
```

检查 `.env` 是否存在、变量值是否正确，以及 `80`、`443` 是否已被占用。

### 访问超时或连接被拒绝

确认容器端口映射：

```bash
docker compose port https-ip 80
docker compose port https-ip 443
```

再依次检查主机防火墙、云安全组、NAT 转发和上游负载均衡。公网环境不能只在服务器本机使用 `curl` 验证，应从外部网络测试。

### 浏览器提示证书不受信任

- `MODE=selfsigned`：这是预期行为。
- `LETSENCRYPT_STAGING=1`：staging 证书不会被浏览器信任。
- 正式环境：检查证书 SAN 是否包含访问的公网 IP，以及 Nginx 是否已 reload。

### Certbot 申请失败

```bash
docker compose logs --tail=300 https-ip
docker compose exec https-ip sh -c 'ls -la /var/www/certbot /etc/letsencrypt'
```

优先检查公网 `80` 是否直达本容器、`PUBLIC_IP` 是否正确、时间是否同步以及是否触发 ACME 速率限制。修复后等待下一次检查或重新创建容器。

### 页面内容未更新

确认已重新构建镜像，并清理浏览器缓存后再次请求：

```bash
docker compose up -d --build
curl -fsS https://公网IP/
```

## 10. 停止与卸载

临时停止但保留证书数据：

```bash
docker compose stop
```

停止并删除容器、网络，但保留命名卷：

```bash
docker compose down
```

彻底卸载并删除证书数据前，必须先完成备份并确认无恢复需求：

```bash
docker compose down -v
```

该命令不可通过本服务恢复已删除的卷数据。
