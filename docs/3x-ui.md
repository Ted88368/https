# 3x-ui 接入本 Nginx 反代指南

本仓库的 Nginx（容器 `https-ip`）在 443 上做 TLS 终止，并通过 `location /` 把请求反代到宿主机的 `http://host.docker.internal:8000/`。本文说明如何让 3x-ui 面板跑在 8000 端口、由 Nginx 统一提供 HTTPS。

## 1. 3x-ui 侧配置

编辑 `/etc/x-ui/config.json`，关键字段：

```json
{
  "webHost": "0.0.0.0",
  "webPort": 8000,
  "webCertFile": "",
  "webKeyFile": "",
  "webBasePath": ""
}
```

| 字段 | 取值 | 说明 |
| --- | --- | --- |
| `webHost` | `0.0.0.0` | **必须**，不能填 `127.0.0.1`。Nginx 通过 Docker 网桥网关 IP（`host.docker.internal` → `172.17.0.1`）访问宿主机，只绑本地会导致 Nginx 连不上，表现为 **502**。 |
| `webPort` | `8000` | 需与 Nginx 模板中 `proxy_pass http://host.docker.internal:8000/` 的端口一致。 |
| `webCertFile` / `webKeyFile` | 留空 | 关闭 3x-ui 自带 HTTPS，TLS 统一由 Nginx 处理，避免双重加密。 |
| `webBasePath` | `""` 或 `"/xui"` | 留空则根路径 `/` 直接是面板；填 `/xui` 则面板在子路径，需配合 `locations.d/3x-ui.conf`。 |

> 也可用交互命令：`x-ui setting`，按提示把监听 IP 改成 `0.0.0.0`、端口 `8000`、证书留空，再 `x-ui restart`。

## 2. 重启与验证

```bash
x-ui restart

# 确认监听在 0.0.0.0:8000（不是 127.0.0.1）
sudo ss -ltnp | grep -E ':8000\b'

# 本机直连 3x-ui 应返回 200
curl -fsSI http://127.0.0.1:8000/ | head

# 外部经 Nginx 访问应进面板、不再 502
curl -k -o /dev/null -w "%{http_code}\n" https://<公网IP>/
```

## 3. Nginx 侧（本仓库）

- 根路径 `/` 已在 `docker/nginx.conf.template` 中反代到 8000，无需改动。
- 若用子路径（如 `/xui/`），在 `locations.d/3x-ui.conf` 中配置，并把 `webBasePath` 设为 `/xui`：

```nginx
location /xui/ {
    proxy_pass http://host.docker.internal:8000/;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_connect_timeout 60s;
    proxy_read_timeout 60s;
    proxy_send_timeout 60s;
}
```

> 修改 Nginx 模板或 `locations.d/` 后必须重新构建镜像：
> `docker compose up -d --build --force-recreate`

## 4. 常见故障

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 根路径 503 | 8000 端口无任何进程监听 | 确认 3x-ui 已启动，`ss -ltnp \| grep 8000` |
| 根路径 502 | 3x-ui 只绑 `127.0.0.1` / Nginx 网关连不进 | 改 `webHost` 为 `0.0.0.0` 并重启 |
| 地址栏“不安全”但能进页面 | 混合内容：页面引用了 `http://` 资源 | 见第 5 节 |
| 证书名称不匹配 | 用域名访问，但证书 SAN 只有 IP | 用 `https://<IP>/` 访问，或另申请域名证书 |

## 5. 混合内容（Mixed Content）

若面板能打开但浏览器显示“不安全”，通常是 3x-ui 返回的页面里含有 `http://` 绝对地址。排查：

1. 浏览器打开 `https://<IP>/`，F12 → Console，找红色 `Mixed Content: ...` 行，记下其中的 `http://` 地址。
2. 在本仓库 Nginx 模板的根反代 `location /` 中，加入以下任意一种修复：

   - 推荐：让浏览器自动把子资源升级为 HTTPS
     ```nginx
     add_header Content-Security-Policy "upgrade-insecure-requests" always;
     ```
   - 或更精准：把响应中的 `http://<IP>` 改写成 `https://<IP>`
     ```nginx
     proxy_set_header Accept-Encoding "";
     sub_filter 'http://<IP>' 'https://<IP>';
     sub_filter_once off;
     ```

修改后重新构建镜像并验证。
