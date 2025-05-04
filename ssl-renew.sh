#!/bin/bash

domain="$1"
certs_dir="$2"

PHP_CONTAINER=$(docker ps -a --format "{{.Names}}" | grep -E "^php-" | head -n 1)
NGINX_CONTAINER=$(docker ps -a --format "{{.Names}}" | grep -E "^nginx-" | head -n 1)

docker exec $PHP_CONTAINER certbot certonly --force-renew --preferred-chain "ISRG Root X1" \
    -n --agree-tos --email "mail@$domain" -d "$domain" --webroot -w /certs/ \
    --logs-dir /logs --max-log-backups 0 --cert-name "$domain" && \
docker exec $PHP_CONTAINER cat "/etc/letsencrypt/live/$domain/fullchain.pem" > \
    "${certs_dir}/${domain}/fullchain.pem" && \
docker exec $PHP_CONTAINER cat "/etc/letsencrypt/live/$domain/privkey.pem" > \
    "${certs_dir}/${domain}/privkey.pem" && \
docker restart $NGINX_CONTAINER