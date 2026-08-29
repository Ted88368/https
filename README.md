# HTTPS IP Service

基于 Docker 的 HTTPS 服务示例，使用公网 IP 直接申请 Let's Encrypt IP 地址证书，并自动续签。

## Ubuntu 原生一键安装（非 Docker）

Ubuntu 服务器可直接使用 Nginx、Certbot 和 systemd 部署，不需要 Docker：

```bash
sudo -E MODE=letsencrypt PUBLIC_IP=你的公网IP ACME_EMAIL=运维邮箱 ./install.sh
```

也可以在项目根目录创建 `.env`，脚本部署和 Docker Compose 都会读取其中的配置：

```env
MODE=letsencrypt
PUBLIC_IP=你的公网IP
ACME_EMAIL=运维邮箱
LETSENCRYPT_STAGING=0
```

然后执行：

```bash
sudo ./install.sh
```

注意：直接执行 `sudo ./install.sh` 使用的是 `MODE=selfsigned`，浏览器必然显示“不安全”。要使用浏览器信任的证书，必须填写公网 IP 并显式使用 `MODE=letsencrypt`；`LETSENCRYPT_STAGING=1` 也只会签发浏览器不信任的测试证书。

脚本会安装 Nginx 和 Certbot（独立 Python venv），部署 `public/index.html`，配置 80/443 端口，并创建每 6 小时运行一次的 `https-ip-renew.timer`。80 端口的普通请求会反向代理到 `http://host.docker.internal:19090/`，ACME 校验路径除外。公网 IP 证书要求外部可访问 TCP 80 和 443；建议先用 staging 验证：

```bash
sudo -E MODE=letsencrypt PUBLIC_IP=你的公网IP ACME_EMAIL=运维邮箱 LETSENCRYPT_STAGING=1 ./install.sh
```

仅验证 Nginx 和 HTTPS 链路时可使用默认的自签名模式：

```bash
sudo ./install.sh
curl -k https://127.0.0.1/
```

查看状态和续签日志：

```bash
systemctl status nginx https-ip-renew.timer
journalctl -u https-ip-renew.service
```

卸载原生部署（保留系统中的其他 Nginx/Certbot 证书）：

```bash
sudo ./uninstall.sh
```

## 前提

- 服务器有公网 IPv4 或 IPv6。
- 公网 `80` 和 `443` 端口能直接访问到运行容器的机器。
- 使用 Certbot `--ip-address` 和 Let's Encrypt `shortlived` profile。IP 地址证书有效期约 160 小时，因此容器默认每 6 小时检查续签。

Let's Encrypt 已在 2026-01-15 宣布 IP 地址证书一般可用；Certbot 从 5.3 起支持 `--ip-address`，5.4 起支持 IP 地址证书的 `webroot` 模式。

## 测试流程

建议按下面顺序测试：

1. 先用 `MODE=selfsigned` 在本机或局域网验证容器、Nginx、端口映射和 HTTPS 访问。
2. 有公网 IP 后，用 `MODE=letsencrypt` + `LETSENCRYPT_STAGING=1` 验证 Let's Encrypt 校验链路。
3. staging 成功后，再把 `LETSENCRYPT_STAGING=0` 切到正式证书。

### 本机测试

本机测试不需要公网 IP，也不会调用 Let's Encrypt。它只用于确认 Docker 服务能启动、`443` 端口能访问、Nginx 能正确返回页面。

内网 IP 不能申请 Let's Encrypt 公网受信任证书，但可以先用自签名证书测试 Docker、Nginx、HTTPS 访问链路。

```bash
cp .env.example .env
```

保持 `.env` 里：

```env
MODE=selfsigned
PUBLIC_IP=127.0.0.1
```

启动：

```bash
docker compose up -d --build
docker compose logs -f https-ip
```

访问：

```bash
https://127.0.0.1/
```

浏览器会提示证书不受信任，这是自签名证书的正常现象。也可以用命令测试：

```bash
curl -k https://127.0.0.1/
```

预期结果：

- `docker compose logs -f https-ip` 里出现 `Running with self-signed certificate only; Certbot is disabled`。
- 浏览器访问 `https://127.0.0.1/` 时会提示证书不受信任。
- `curl -k https://127.0.0.1/` 能返回 HTML。

### 文件下载服务

服务内置了专门的文件下载目录 `/downloads/`：

- **访问地址**：`https://<你的IP或域名>/downloads/`
- **目录索引**：默认开启自动目录索引（Autoindex），支持通过浏览器直接浏览并下载文件。
- **文件存放**：
  - **Docker 部署**：直接将需下载的文件放入宿主机的 `./public/downloads/` 目录中。
  - **Ubuntu 原生部署**：将文件放入 `/var/www/https-ip/html/downloads/` 目录中。

可以使用 curl 测试下载示例文件：

```bash
curl -k -O "https://127.0.0.1/downloads/2026-交割日日历.ics"
```

### HTTP 反向代理服务

服务支持通过配置环境变量 `PROXY_PASS` 直接启用 HTTP 反向代理功能：

- **配置方式**：在 `.env` 或环境变量中设置 `PROXY_PASS=http://<后端IP或主机名>:<端口>`（例如 `PROXY_PASS=http://127.0.0.1:8080` 或 Docker 环境下的 `http://backend:8080`）。
- **工作机制**：设置后，所有针对主站入口 `https://<你的IP>/` 的请求将自动代理至目标后端服务，并包含必要的 HTTP/WebSocket 报头。同时 `/downloads/` 目录文件下载功能保持独立不受影响。
- **未配置时**：默认提供 `public/index.html` 静态内容。


### 局域网测试

局域网测试适合验证同一内网里的其他机器能否访问这个 HTTPS 服务。它仍然使用自签名证书，不会得到公网受信任证书。

先查运行 Docker 机器的内网 IP，例如 `192.168.1.20`，然后把 `.env` 改成：

```env
MODE=selfsigned
PUBLIC_IP=192.168.1.20
```

然后访问：

```bash
https://192.168.1.20/
```

命令行测试：

```bash
curl -k https://192.168.1.20/
```

如果其他机器访问不了，优先检查：

- Docker 主机防火墙是否放行 `443`。
- `docker compose ps` 是否显示 `0.0.0.0:443->443/tcp`。
- `PUBLIC_IP` 是否填的是 Docker 主机的局域网 IP，而不是容器内 IP。

### 公网 staging 测试

公网 staging 测试用于验证真实的 ACME 校验链路，但签出来的仍然是测试证书，浏览器不会信任它。这样可以避免一开始就撞正式环境的频率限制。

前提：

- `PUBLIC_IP` 必须是公网 IPv4 或 IPv6。
- 公网 `80` 和 `443` 端口必须能访问到这台 Docker 主机。
- 如果云厂商有安全组，需要放行入站 TCP `80` 和 `443`。

```bash
cp .env.example .env
vi .env
```

公网测试时，`.env` 至少要设置：

```env
MODE=letsencrypt
PUBLIC_IP=你的公网IP
LETSENCRYPT_STAGING=1
```

启动：

```bash
docker compose up -d --build
docker compose logs -f https-ip
```

预期结果：

- 日志里能看到 Certbot 申请或复用证书成功。
- `curl -k https://你的公网IP/` 能返回 HTML。
- 浏览器可能仍然提示证书不受信任，因为 staging 证书本来就不是正式可信证书。

### 正式证书测试

确认 staging 成功后，再改成正式证书：

```env
LETSENCRYPT_STAGING=0
```

重建启动。staging 和正式证书使用不同的 Certbot 证书名，所以测试证书不会阻碍正式证书签发：

```bash
docker compose up -d --build --force-recreate
```

访问：

```bash
https://你的公网IP/
```

预期结果：

- 浏览器不再提示证书不受信任。
- 证书信息里能看到 IP 地址在 Subject Alternative Name 中。
- 后续容器会按 `RENEW_INTERVAL_SECONDS` 自动检查续签，续签成功后自动 reload Nginx。

### 常用验证命令

查看容器状态：

```bash
docker compose ps
```

查看日志：

```bash
docker compose logs -f https-ip
```

查看 HTTPS 返回：

```bash
curl -k https://127.0.0.1/
```

查看证书主题：

```bash
openssl s_client -connect 127.0.0.1:443 -showcerts </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

## 配置

| 变量 | 说明 |
| --- | --- |
| `MODE` | `selfsigned` 用于本机/内网测试，`letsencrypt` 用于公网真实签发 |
| `PUBLIC_IP` | `MODE=letsencrypt` 时必须是公网 IP；`MODE=selfsigned` 时可用内网 IP 或 `127.0.0.1` |
| `ACME_EMAIL` | 可选但建议填写，用于 Let's Encrypt 通知 |
| `LETSENCRYPT_STAGING` | `1` 使用测试证书，`0` 使用正式证书 |
| `RENEW_INTERVAL_SECONDS` | 自动续签检查间隔，默认 `21600` 秒 |
| `SERVER_NAME` | Nginx `server_name`，默认同时匹配 `_` 和 `PUBLIC_IP`；如需域名可显式设置 |
| `PROXY_LOCATION` | 可选，HTTP 反向代理的 Location 匹配路径（如 `/etf`），默认 `/` |
| `PROXY_PASS` | 可选，HTTP 反向代理目标地址（如 `http://101.200.183.179`），为空时提供静态 index.html |

证书和账号数据保存在 Docker volume：

- `letsencrypt`: Certbot 账号、订单、证书目录
- `nginx-certs`: Nginx 当前加载的证书文件

## 替换站点内容与反向代理

默认静态页面在 `public/index.html`。

### 1. 单服务反向代理（基于 `.env`）

如果只有一个后端服务，直接在 `.env` 中设置：

```env
# 示例：将主站根路径 / 代理至后端服务
PROXY_LOCATION=/
PROXY_PASS=http://host.docker.internal:8080
```

或将指定前缀代理至后端：

```env
# 示例：将 /etf 路径代理至指定后端
PROXY_LOCATION=/etf
PROXY_PASS=http://101.200.183.179
```

修改后重新应用配置：

```bash
docker compose up -d --build --force-recreate
```

---

### 2. 多服务反向代理（基于 `locations.d/` 模块化配置）

如果有多个后端服务（如 `/api/` 转发到服务 A、`/admin/` 转发到服务 B），可在 `locations.d/` 目录下放置独立的 `.conf` 文件：

1. 参考 `locations.d/example.conf.example`，在 `locations.d/` 目录下创建 `.conf` 文件（例如 `locations.d/services.conf`）：

```nginx
# 服务 1：API 接口服务 -> 宿主机 8001 端口
location /api/ {
    proxy_pass http://host.docker.internal:8001/;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
}

# 服务 2：管理后台 -> 宿主机 8002 端口
location /admin/ {
    proxy_pass http://host.docker.internal:8002/;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

2. 重建/重启服务生效：

```bash
docker compose up -d --build --force-recreate
```

> **提示（关于 `proxy_pass` 末尾的斜杠 `/`）**：
> - `proxy_pass http://host.docker.internal:8001/;`（带 `/`）：访问 `https://<IP>/api/user` 会被重写为 `http://host.docker.internal:8001/user`（去除了 `/api` 前缀）。
> - `proxy_pass http://host.docker.internal:8001;`（不带 `/`）：访问 `https://<IP>/api/user` 会直接请求 `http://host.docker.internal:8001/api/user`（保留了 `/api` 前缀）。

如需更复杂的自定义 Nginx 路由规则，也可直接修改 `docker/nginx.conf.template`（Docker 部署）或 `/etc/nginx/sites-available/https-ip.conf`（Ubuntu 原生部署）。

