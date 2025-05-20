#!/bin/bash

set -u

GREEN="\033[32m"
RED="\033[91m"
RESET="\033[0m"

CONFIG_DIR="/root/vpnbot/config"
CERTS_DIR="/root/vpnbot/certs" 
INCLUDE_CONF="${CONFIG_DIR}/include.conf"

init() {
    NGINX_CONTAINER_NAME=$(docker ps -a --format "{{.Names}}" | grep -E '^nginx-' | head -n 1)
    if [ -z "$NGINX_CONTAINER_NAME" ]; then
        echo -e "${RED}Ошибка: Не найден контейнер nginx.${RESET}"
        exit 1
    fi
    
    PHP_CONTAINER_NAME=$(docker ps -a --format "{{.Names}}" | grep -E '^php-' | head -n 1)
    if [ -z "$PHP_CONTAINER_NAME" ]; then
        echo -e "${RED}Ошибка: Не найден контейнер PHP.${RESET}"
        exit 1
    fi
    
}

restart_nginx() {
    echo "Перезапускаем контейнер $NGINX_CONTAINER_NAME..."
    docker restart "$NGINX_CONTAINER_NAME" > /dev/null && \
        echo -e "${GREEN}Контейнер $NGINX_CONTAINER_NAME перезагружен.${RESET}" || \
        echo -e "${RED}Ошибка: Не удалось перезапустить контейнер $NGINX_CONTAINER_NAME.${RESET}"
}

issue_cert() {
    local domain=$1
    local cert_dir="${CERTS_DIR}/$domain"
    
    echo "Выпускаем SSL-сертификат для $domain..."

    if [ -d "$cert_dir" ] && [ -f "$cert_dir/fullchain.pem" ] && [ -f "$cert_dir/privkey.pem" ]; then
        read -rp "SSL-сертификат уже существует в ${CERTS_DIR}. Перевыпустить? (Y/N): " choice
        if [[ ! "$choice" =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi

    if ! docker exec "$PHP_CONTAINER_NAME" certbot certonly --force-renew --preferred-chain 'ISRG Root X1' \
        -n --agree-tos --email "mail@$domain" -d "$domain" --webroot -w /certs/ \
        --logs-dir /logs --max-log-backups 0 --cert-name "$domain"; then
        echo -e "${RED}Ошибка: Не удалось выпустить SSL-сертификат для $domain.${RESET}"
        return 1
    fi
        
    rm -rf "$cert_dir"
    mkdir -p "$cert_dir"
    
    docker exec "$PHP_CONTAINER_NAME" cat "/etc/letsencrypt/live/$domain/fullchain.pem" > "$cert_dir/fullchain.pem"
    docker exec "$PHP_CONTAINER_NAME" cat "/etc/letsencrypt/live/$domain/privkey.pem" > "$cert_dir/privkey.pem"

    echo -e "${GREEN}SSL-сертификат для $domain успешно выпущен!${RESET}"
    return 0
}

remove_cert() {
    local domain=$1
    local cert_dir="${CERTS_DIR}/$domain"
    
    echo "Удаляем SSL-сертификат и папку из ${CERTS_DIR}..."
    
    if [ -d "$cert_dir" ]; then
        rm -rf "$cert_dir"
        echo -e "${GREEN}SSL-сертификат и папка удалены из ${CERTS_DIR}!${RESET}"
        return 0
    else
        echo -e "${RED}Ошибка: SSL-сертификат для $domain не найден в ${CERTS_DIR}.${RESET}"
        return 1
    fi
}

check_service_availability() {
    local ip_part=$1
    local port_part=$2
    local service_ip="$ip_part:$port_part"
    
    echo "Проверяем доступность сервиса $service_ip из контейнера $NGINX_CONTAINER_NAME..."
    nc_output=$(docker exec "$NGINX_CONTAINER_NAME" timeout 1 nc -zv "$ip_part" "$port_part" 2>&1)
    nc_exit_code=$?
    
    if [[ "$nc_output" == *"open"* ]] && [[ $nc_exit_code -eq 0 ]]; then
        echo -e "${GREEN}Сервис $service_ip доступен из контейнера nginx!${RESET}"
        return 0
    else
        echo -e "${RED}Ошибка: Сервис $service_ip не доступен из контейнера nginx!${RESET}"
        return 1
    fi
}

install_site() {
    local domain=$1
    local service_ip=$2
    local cert_dir="${CERTS_DIR}/$domain"
    
    local marker="# BEGIN SSL CONFIG: $domain"
    local end_marker="# END SSL CONFIG: $domain"
    
    local ip_part=$(echo "$service_ip" | cut -d':' -f1)
    local port_part=$(echo "$service_ip" | cut -d':' -f2)

    if [ ! -d "$cert_dir" ] || [ ! -f "$cert_dir/fullchain.pem" ] || [ ! -f "$cert_dir/privkey.pem" ]; then
        echo -e "${RED}Ошибка: SSL-сертификат не найден в $cert_dir. Сначала выпустите его.${RESET}"
        return 1
    fi
    
    if ! check_service_availability "$ip_part" "$port_part"; then
        while true; do
            read -rp "Изменить IP и порт сервиса (в противном случае отмена операции)? (Y/N): " choice
            
            case "$choice" in
                [Yy])
                    read -rp "Введите новый адрес сервиса (IP:порт): " service_ip
                    ip_part=$(echo "$service_ip" | cut -d':' -f1)
                    port_part=$(echo "$service_ip" | cut -d':' -f2)
                    
                    if check_service_availability "$ip_part" "$port_part"; then
                        break
                    fi
                    ;;
                [Nn])
                    echo "Операция отменена пользователем."
                    return 1
                    ;;
                *)
                    echo "Неверный выбор. Пожалуйста, введите Y или N."
                    ;;
            esac
        done
    fi

    echo "Добавляем конфигурацию сайта $domain..."

    if grep -q "$marker" "$INCLUDE_CONF"; then
        read -rp "Конфигурация уже существует. Перезаписать? (Y/N): " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            sed -i "/$marker/,/$end_marker/d" "$INCLUDE_CONF"
        else
            return 1
        fi
    fi

    local zone_name="${domain//./_}_limit"
    local conn_zone_name="${domain//./_}_conn"

    cat <<EOF >> "$INCLUDE_CONF"
$marker
limit_req_zone \$binary_remote_addr zone=${zone_name}:10m rate=10r/s;
limit_conn_zone \$binary_remote_addr zone=${conn_zone_name}:10m;
limit_req_status 429;
limit_conn_status 429;

server {
    server_name $domain;

    listen 10.10.0.2:443 ssl http2 proxy_protocol;
    listen 10.10.1.2:443 ssl http2;

    ssl_certificate /certs/$domain/fullchain.pem;
    ssl_certificate_key /certs/$domain/privkey.pem;
    ssl_trusted_certificate /certs/$domain/fullchain.pem;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:1m;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;

    client_max_body_size 0;

    real_ip_recursive on;
    set_real_ip_from 10.10.0.10;

    location / {
        limit_req zone=${zone_name} burst=20 nodelay;
        limit_conn ${conn_zone_name} 10;
        
        proxy_pass http://$service_ip;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
    }
}
$end_marker
EOF

    echo -e "${GREEN}Конфигурация сайта $domain успешно добавлена!${RESET}"
    return 0
}

remove_site() {
    local domain=$1
    
    if grep -q "^# BEGIN SSL CONFIG: $domain$" "$INCLUDE_CONF"; then
        sed -i "/# BEGIN SSL CONFIG: $domain/,/# END SSL CONFIG: $domain/d" "$INCLUDE_CONF"
        echo -e "${GREEN}Конфигурация сайта $domain удалена!${RESET}"
        return 0
    else
        echo -e "${RED}Конфигурация сайта $domain не найдена.${RESET}"
        return 1
    fi
}

enable_auto_renew() {
    local domain=$1
    local cert_dir="${CERTS_DIR}/$domain"
    local marker="auto_renew_${domain}"
    
    echo "Настраиваем автообновление SSL-сертификата для $domain..."
    
    if [ ! -d "$cert_dir" ] || [ ! -f "$cert_dir/fullchain.pem" ] || [ ! -f "$cert_dir/privkey.pem" ]; then
        echo -e "${RED}Ошибка: SSL-сертификат не найден в $cert_dir. Сначала выпустите его.${RESET}"
        return 1
    fi
    
    if crontab -l 2>/dev/null | grep -q "$marker"; then
        echo -e "${GREEN}Автообновление SSL-сертификата для $domain уже настроено.${RESET}"
        return 0
    fi
    
    local crontab_cmd="@monthly /usr/bin/flock -x /tmp/certbot_renew.lock bash -c 'curl -fsSL https://raw.githubusercontent.com/triplebleed/vpnbot-ssl-manager/refs/heads/main/ssl-renew.sh | bash -s -- \"$domain\" \"$CERTS_DIR\"' # ${marker}"

    (crontab -l 2>/dev/null || echo "") | { cat; echo "$crontab_cmd"; } | crontab -
    
    echo -e "${GREEN}Автообновление SSL-сертификата для $domain настроено (@monthly).${RESET}"
    return 0
}

remove_auto_renew() {
    local domain=$1
    local marker="auto_renew_${domain}"
    
    echo "Удаляем автообновление SSL-сертификата для $domain..."
    
    if crontab -l 2>/dev/null | grep -q "${marker}[[:space:]]\\|${marker}$"; then
        crontab -l 2>/dev/null | grep -v "$marker" | crontab -
        echo -e "${GREEN}Автообновление SSL-сертификата для $domain успешно удалено!${RESET}"
    else
        echo -e "${RED}Автообновление SSL-сертификата для $domain не найдено.${RESET}"
    fi
    
    return 0
}

print_menu() {
    clear
    echo "╔══════════════════════════════════════════════════╗"
    echo "║                VPNBOT SSL MANAGER                ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo "Выберите действие:"
    echo ""
    echo "УСТАНОВКА:"
    echo "1) Комплексная установка (SSL + конфиг сайта + автообновление)"
    echo "2) Выпустить SSL-сертификат и скопировать в vpnbot/certs"
    echo "3) Добавить конфигурацию сайта в include.conf"
    echo "4) Включить автообновление SSL-сертификата"
    echo ""
    echo "УДАЛЕНИЕ:"
    echo "5) Комплексное удаление (SSL + конфиг сайта + автообновление)"
    echo "6) Удалить SSL-сертификат"
    echo "7) Удалить конфигурацию сайта"
    echo "8) Отключить автообновление SSL-сертификата"
    echo ""
    echo "9) Выход"
    echo ""
}

main() {
    init
    
    while true; do
        print_menu
        
        read -rp "Введите номер операции [1-9]: " opt
        case $opt in
            1)
                read -rp "Домен (например: sub.example.com): " domain
                read -rp "IP или docker-сеть и порт сервиса (например: uptime-kuma:3001): " service_ip
                issue_cert "$domain"
                install_site "$domain" "$service_ip" && restart_nginx
                enable_auto_renew "$domain"
                ;;
            2)
                read -rp "Домен (например: sub.example.com): " domain
                issue_cert "$domain" && restart_nginx
                ;;
            3)
                read -rp "Домен (например: sub.example.com): " domain
                read -rp "IP или docker-сеть и порт сервиса (например: uptime-kuma:3001): " service_ip
                install_site "$domain" "$service_ip" && restart_nginx
                ;;
            4)
                read -rp "Домен (например: sub.example.com): " domain
                enable_auto_renew "$domain"
                ;;
            5)
                read -rp "Домен (например: sub.example.com): " domain
                remove_cert "$domain"
                remove_site "$domain"
                remove_auto_renew "$domain"
                restart_nginx
                ;;
            6)
                read -rp "Домен (например: sub.example.com): " domain
                remove_cert "$domain" && restart_nginx
                ;;
            7)
                read -rp "Домен (например: sub.example.com): " domain
                remove_site "$domain" && restart_nginx
                ;;
            8)
                read -rp "Домен (например: sub.example.com): " domain
                remove_auto_renew "$domain"
                ;;
            9)
                echo "Выход из программы..."
                exit 0
                ;;
            *)
                echo -e "\nНеверный выбор. Пожалуйста, повторите."
                ;;
        esac

        echo -e "\nОперация завершена. Нажмите Enter, чтобы вернуться в меню..."
        read -r
    done
}

main
