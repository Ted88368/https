FROM docker.m.daocloud.io/library/python:3.13-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends nginx openssl ca-certificates curl \
    && pip install -i https://pypi.tuna.tsinghua.edu.cn/simple --no-cache-dir "certbot>=5.4" \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# 下载 ISRG X1 根证书，用于补全 Let's Encrypt shortlived 证书的证书链
RUN mkdir -p /etc/nginx/certs \
    && curl -fsSL https://letsencrypt.org/certs/isrgrootx1.pem -o /etc/nginx/certs/isrg-x1.pem

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/nginx.conf.template /etc/nginx/templates/default.conf.template
COPY public/ /usr/share/nginx/html/

RUN chmod +x /usr/local/bin/entrypoint.sh \
    && mkdir -p /var/www/certbot /etc/nginx/certs/live /var/log/nginx /etc/nginx/conf.d/locations \
    && rm -f /etc/nginx/sites-enabled/default

EXPOSE 80 443

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
