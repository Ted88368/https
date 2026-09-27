# 3x-ui 接入本 Nginx 反代指南

本仓库的 Nginx（容器 `https-ip`）在 443 上做 TLS 终止，并通过 `location /` 把请求反代到宿主机的 `http://host.docker.internal:8000/`。本文说明如何让 3x-ui 面板与订阅服务全部由 Nginx 统一在标准 443 端口提供 HTTPS，杜绝外部客户端直连非标端口（如 2096）。

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

## 4. 订阅服务 443 反代与面板配置

### 4.1 背景与设计原则

- 外部客户端（V2Ray、Clash、Mihomo、Sing-box 等）获取订阅必须走标准 HTTPS（443 端口），由 Nginx 管理的有效 TLS 证书终结加密。
- 严禁将客户端直接暴露或引导连接到 3x-ui 内部监听的 2096 端口。
- 3x-ui 订阅服务默认监听在宿主机 2096 端口（HTTPS），Nginx 将 443 端口上的全格式订阅请求统一反向代理到宿主机（`https://host.docker.internal:2096`）。

### 4.2 Nginx 侧反代配置 (`locations.d/subscription.conf`)

在 `locations.d/subscription.conf` 中配置全格式订阅路由的反向代理规则：

- `/c3Vi`：通用订阅（Base64 / V2Ray 等）
- `/clash`：Clash 格式订阅
- `/mihomo`：Mihomo 格式订阅
- `/json`：Sing-box JSON 格式订阅

```nginx
# 3x-ui 订阅通过 nginx 443 反代
# 客户端通过标准 HTTPS (443) 访问：
#   https://<公网IP或域名>/c3Vi/<订阅ID>
#   https://<公网IP或域名>/clash/<订阅ID>
#   https://<公网IP或域名>/mihomo/<订阅ID>
#   https://<公网IP或域名>/json/<订阅ID>
# 后端反代到宿主机的 3x-ui 订阅服务 (host.docker.internal:2096)

location /c3Vi {
    proxy_pass https://host.docker.internal:2096;
    proxy_ssl_verify off;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 60s;
}

location /clash {
    proxy_pass https://host.docker.internal:2096;
    proxy_ssl_verify off;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 60s;
}

location /mihomo {
    proxy_pass https://host.docker.internal:2096;
    proxy_ssl_verify off;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 60s;
}

location /json {
    proxy_pass https://host.docker.internal:2096;
    proxy_ssl_verify off;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 60s;
}
```

配置添加或更新后，重新构建并启动 Nginx 容器：
```bash
docker compose up -d --build --force-recreate
```

### 4.3 3x-ui 面板侧配置（彻底去除 :2096 端口与二维码适配）

仅配置 Nginx 反代后，3x-ui 面板生成的订阅链接和二维码默认仍会读取自身监听的 2096 端口进行拼接。需通过 3x-ui 面板内置的「反向代理 URI」功能修正。

**操作步骤**：
1. 登录 3x-ui Web 面板，进入 **面板设置** -> **订阅设置**。
2. 找到 **反向代理 URI**（Sub URI）输入框，填入完整基础 URL：
   ```text
   https://<公网IP或域名>/c3Vi/
   ```
   > **注意**：末尾必须保留斜杠 `/`。使用 IP 证书时填写公网 IP，使用域名证书时填写域名。
3. 点击 **保存配置**。
4. 在宿主机执行重启命令，使配置立即生效：
   ```bash
   x-ui restart
   ```

**原理解析**：
- 3x-ui 内部在生成订阅链接时（`BuildURLs`）：
  - 通用订阅会直接使用填写的反向代理 URI 拼接订阅 ID：`https://<公网IP或域名>/c3Vi/<subId>`。
  - 3x-ui 会自动通过 `extractBaseFromURI` 从中抽取出基础地址 `https://<公网IP或域名>`。
  - Clash（`/clash/`）、Mihomo（`/mihomo/`）与 JSON（`/json/`）端点均会自动继承该基础地址，彻底剔除 `:2096`。
  - 面板上显示的各格式订阅链接、一键复制功能及弹出的二维码均会自动更新为标准的 443 端口 HTTPS 链接。

### 4.4 验证订阅访问
在终端中执行测试命令，验证所有订阅端点均能通过 443 端口正常响应（替换 `<公网IP或域名>` 与 `<订阅ID>`）：

```bash
# 通用订阅 (Base64)
curl -fsSI https://<公网IP或域名>/c3Vi/<订阅ID>

# Clash 订阅
curl -fsSI https://<公网IP或域名>/clash/<订阅ID>

# Mihomo 订阅
curl -fsSI https://<公网IP或域名>/mihomo/<订阅ID>

# JSON 订阅
curl -fsSI https://<公网IP或域名>/json/<订阅ID>
```
正常均应返回 HTTP `200` 状态码。

## 5. 常见故障

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 根路径 503 | 8000 端口无任何进程监听 | 确认 3x-ui 已启动，`ss -ltnp \| grep 8000` |
| 根路径 502 | 3x-ui 只绑 `127.0.0.1` / Nginx 网关连不进 | 改 `webHost` 为 `0.0.0.0` 并重启 |
| 订阅端点 502 | 宿主机 3x-ui 订阅服务未监听 2096 端口 | 检查 3x-ui 面板设置中订阅端口是否为 2096 并开启 |
| 订阅链接仍带 `:2096` | 3x-ui 未配置反向代理 URI 或未重启 | 在订阅设置填入 `https://<公网IP或域名>/c3Vi/` 并执行 `x-ui restart` |
| 地址栏“不安全”但能进页面 | 混合内容：页面引用了 `http://` 资源 | 见第 6 节 |
| 证书名称不匹配 | 用域名访问，但证书 SAN 只有 IP | 用 `https://<IP>/` 访问，或另申请域名证书 |

## 6. 混合内容（Mixed Content）

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
