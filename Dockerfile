FROM python:3.13-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends nginx openssl ca-certificates \
    && pip install --no-cache-dir "certbot>=5.4" \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/nginx.conf.template /etc/nginx/templates/default.conf.template
COPY public/ /usr/share/nginx/html/

RUN chmod +x /usr/local/bin/entrypoint.sh \
    && mkdir -p /var/www/certbot /etc/nginx/certs/live /var/log/nginx \
    && rm -f /etc/nginx/sites-enabled/default

EXPOSE 80 443

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
