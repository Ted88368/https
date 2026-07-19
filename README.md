# Docker HTTPS IP Service

基于 Docker 的 HTTPS 服务示例，使用公网 IP 直接申请 Let's Encrypt IP 地址证书，并自动续签。

## 前提

- 服务器有公网 IPv4 或 IPv6。
- 公网 `80` 和 `443` 端口能直接访问到运行容器的机器。
- 使用 Certbot `--ip-address` 和 Let's Encrypt `shortlived` profile。IP 地址证书有效期约 160 小时，因此容器默认每 6 小时检查续签。

Let's Encrypt 已在 2026-01-15 宣布 IP 地址证书一般可用；Certbot 从 5.3 起支持 `--ip-address`，5.4 起支持 IP 地址证书的 `webroot` 模式。

## 使用

```bash
cp .env.example .env
vi .env
docker compose up -d --build
docker compose logs -f https-ip
```

建议先保持：

```env
LETSENCRYPT_STAGING=1
```

日志确认 staging 签发成功后，再改成：

```env
LETSENCRYPT_STAGING=0
```

然后重建启动。staging 和正式证书使用不同的 Certbot 证书名，所以测试证书不会阻碍正式证书签发：

```bash
docker compose up -d --build --force-recreate
```

访问：

```bash
https://你的公网IP/
```

## 配置

| 变量 | 说明 |
| --- | --- |
| `PUBLIC_IP` | 必填，证书要绑定的公网 IP |
| `ACME_EMAIL` | 可选但建议填写，用于 Let's Encrypt 通知 |
| `LETSENCRYPT_STAGING` | `1` 使用测试证书，`0` 使用正式证书 |
| `RENEW_INTERVAL_SECONDS` | 自动续签检查间隔，默认 `21600` 秒 |
| `SERVER_NAME` | Nginx `server_name`，IP 场景通常保持 `_` |

证书和账号数据保存在 Docker volume：

- `letsencrypt`: Certbot 账号、订单、证书目录
- `nginx-certs`: Nginx 当前加载的证书文件

## 替换站点内容

默认静态页面在 `public/index.html`。修改后重新构建：

```bash
docker compose up -d --build
```

如需反向代理到后端服务，可修改 `docker/nginx.conf.template` 中 443 server 的 `location /`。
