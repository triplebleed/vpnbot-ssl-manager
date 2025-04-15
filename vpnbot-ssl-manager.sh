#!/bin/bash

set -u

CONFIG_DIR="/root/vpnbot/config"
CERTS_DIR="/root/vpnbot/certs" 
INCLUDE_CONF="${CONFIG_DIR}/include.conf"
LETSENCRYPT_DIR="/etc/letsencrypt/live"

init() {
    NGINX_CONTAINER_NAME=$(docker ps -a --format "{{.Names}}" | grep -E '^nginx-' | head -n 1)

    if [ -z "$NGINX_CONTAINER_NAME" ]; then
        echo "Ошибка: Не найден контейнер nginx."
        exit 1
    fi
    
    if [ "$(docker inspect -f '{{.State.Running}}' "$NGINX_CONTAINER_NAME")" != "true" ]; then
        echo -e "\nВНИМАНИЕ: Контейнер $NGINX_CONTAINER_NAME не запущен!"
        echo "Операции по установке будут работать некорректно."
        read -rp "Продолжить без запуска контейнера? (Y/N): " choice
        if [[ ! "$choice" =~ ^[Yy]$ ]]; then
            echo "Выход из программы."
            exit 0
        fi
        echo "Продолжаем работу с незапущенным контейнером..."
    fi
}

manage_nginx() {
    local action=$1
    
    case "$action" in
        stop)
            echo "Останавливаем контейнер $NGINX_CONTAINER_NAME..."
            if ! docker stop "$NGINX_CONTAINER_NAME" > /dev/null; then
                echo "Ошибка: Не удалось остановить контейнер $NGINX_CONTAINER_NAME."
                return 1
            fi
            echo "Контейнер $NGINX_CONTAINER_NAME успешно остановлен!"
            ;;
        start)
            echo "Запускаем контейнер $NGINX_CONTAINER_NAME..."
            if ! docker start "$NGINX_CONTAINER_NAME" > /dev/null; then
                echo "Ошибка: Не удалось запустить контейнер $NGINX_CONTAINER_NAME."
                return 1
            fi
            echo "Контейнер $NGINX_CONTAINER_NAME успешно запущен!"
            ;;
        restart)
            echo "Перезапускаем контейнер $NGINX_CONTAINER_NAME..."
            if ! docker restart "$NGINX_CONTAINER_NAME" > /dev/null; then
                echo "Ошибка: Не удалось перезапустить контейнер $NGINX_CONTAINER_NAME."
                return 1
            fi
            echo "Контейнер $NGINX_CONTAINER_NAME успешно перезапущен!"
            ;;
    esac
    
    return 0
}

issue_cert() {
    local domain=$1
    
    if ! command -v certbot &> /dev/null; then
        echo "Certbot не установлен. Установка..."
        sudo apt update
        sudo apt install -y certbot
    fi
    
    echo "Выпускаем SSL-сертификат для $domain..."
    if [ -d "${LETSENCRYPT_DIR}/$domain" ]; then
        echo "SSL-сертификат для $domain уже существует."
        read -rp "Перевыпустить SSL-сертификат? (Y/N): " choice
        if [[ ! "$choice" =~ ^[Yy]$ ]]; then
            echo "Используем существующий SSL-сертификат."
            return 0
        fi
        echo "Перевыпускаем SSL-сертификат..."
    fi

    if ! sudo certbot certonly --standalone --non-interactive -d "$domain"; then
        echo "Ошибка: Не удалось выпустить SSL-сертификат для $domain."
        return 1
    fi
    
    echo "SSL-сертификат для $domain успешно выпущен!"
    return 0
}

copy_cert() {
    local domain=$1
    local cert_dir="${CERTS_DIR}/$domain"
    
    echo "Копируем SSL-сертификат в $cert_dir..."
    
    if [ ! -d "${LETSENCRYPT_DIR}/$domain" ]; then
        echo "Ошибка: SSL-сертификат для домена $domain не найден в ${LETSENCRYPT_DIR}/$domain."
        return 1
    fi
    
    rm -rf "$cert_dir"
    mkdir -p "$cert_dir"
    
    if ! cp -L "${LETSENCRYPT_DIR}/$domain/fullchain.pem" "$cert_dir/fullchain.pem" || \
       ! cp -L "${LETSENCRYPT_DIR}/$domain/privkey.pem" "$cert_dir/privkey.pem"; then
        echo "Ошибка: Не удалось скопировать файлы SSL-сертификата."
        return 1
    fi
    
    echo "SSL-сертификат успешно скопирован в $cert_dir!"
    return 0
}

remove_cert() {
    local domain=$1
    
    if [ ! -d "${LETSENCRYPT_DIR}/$domain" ]; then
        echo "SSL-сертификат для $domain не существует."
        return 1
    fi
    
    echo "Удаляем SSL-сертификат для $domain..."
    if ! echo "Y" | sudo certbot delete --non-interactive --cert-name "$domain"; then
        echo "Ошибка: Не удалось удалить SSL-сертификат для $domain."
        return 1
    fi
    
    echo "Удаляем копию сертификата из ${CERTS_DIR}/$domain..."
    rm -rf "${CERTS_DIR}/$domain"
    
    echo "SSL-сертификат для $domain полностью удален из всех директорий!"
    return 0
}

check_service_availability() {
    local ip_part=$1
    local port_part=$2
    local service_ip="$ip_part:$port_part"
    
    echo "Проверяем доступность сервиса $service_ip из контейнера $NGINX_CONTAINER_NAME..."
    nc_output=$(docker exec "$NGINX_CONTAINER_NAME" timeout 1 nc -zv "$ip_part" "$port_part" 2>&1)
    nc_exit_code=$?
    
    if [[ "$nc_output" == *"open"* ]] && [[ $nc_exit_code -eq 0 ]]; then
        echo -e "Сервис $service_ip доступен из контейнера nginx!"
        return 0
    else
        return 1
    fi
}

install_site() {
    local domain=$1
    local service_ip=$2
    
    local marker="# BEGIN SSL CONFIG: $domain"
    local end_marker="# END SSL CONFIG: $domain"
    
    if [ ! -f "${CERTS_DIR}/${domain}/fullchain.pem" ] || [ ! -f "${CERTS_DIR}/${domain}/privkey.pem" ]; then
        echo "Ошибка: SSL-сертификат для домена $domain не найден в ${CERTS_DIR}/${domain}."
        echo "Сначала выпустите SSL-сертификат для этого домена."
        return 1
    fi

    local ip_part=$(echo "$service_ip" | cut -d':' -f1)
    local port_part=$(echo "$service_ip" | cut -d':' -f2)
    
    if ! check_service_availability "$ip_part" "$port_part"; then
        while true; do
            echo -e "Ошибка: Сервис $service_ip не доступен из контейнера nginx!"
            
            read -rp "Изменить IP и порт сервиса? (Y/N): " choice
            
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
    
    echo "Добавляем конфигурацию для сайта $domain..."
    
    if grep -q "$marker" "$INCLUDE_CONF"; then
        echo "Конфигурация для сайта $domain уже существует."
        read -rp "Сбросить текущую конфигурацию? (Y/N): " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            echo "Перезаписываем конфигурацию..."
            sed -i "/$marker/,/$end_marker/d" "$INCLUDE_CONF"
        else
            echo "Оставляем текущую конфигурацию."
            return 1
        fi
    fi

    cat <<EOF >> "$INCLUDE_CONF"
$marker
server {
    server_name $domain;
    listen 10.10.0.2:443 ssl http2 proxy_protocol;
    listen 10.10.1.2:443 ssl http2;

    ssl_certificate /certs/$domain/fullchain.pem;
    ssl_certificate_key /certs/$domain/privkey.pem;

    location / {
        proxy_pass http://$service_ip;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
$end_marker
EOF

    echo "Конфигурация для сайта $domain успешно добавлена!"
    return 0
}

remove_site() {
    local domain=$1
    
    echo "Удаляем конфигурацию для сайта $domain..."
    
    if grep -q "# BEGIN SSL CONFIG: $domain" "$INCLUDE_CONF"; then
        sed -i "/# BEGIN SSL CONFIG: $domain/,/# END SSL CONFIG: $domain/d" "$INCLUDE_CONF"
        echo "Конфигурация для сайта $domain успешно удалена!"
        return 0
    else
        echo "Конфигурация для сайта $domain не найдена."
        return 1
    fi
}

enable_auto_renew() {
    local domain=$1
    local marker="vpnbot_auto_renew_${domain}"
    
    echo "Настраиваем автообновление SSL-сертификата для $domain..."
    
    if [ ! -f "${CERTS_DIR}/${domain}/fullchain.pem" ] || [ ! -f "${CERTS_DIR}/${domain}/privkey.pem" ]; then
        echo "Ошибка: SSL-сертификат для домена $domain не найден в ${CERTS_DIR}/${domain}."
        echo "Сначала выпустите SSL-сертификат для этого домена."
        return 1
    fi
    
    if crontab -l 2>/dev/null | grep -q "$marker"; then
        echo "Автообновление SSL-сертификата для $domain уже настроено."
        return 0
    fi

    local cron_job="@monthly /usr/bin/flock -x /tmp/certbot_renew.lock /bin/bash -c 'docker stop ${NGINX_CONTAINER_NAME} && sudo certbot renew --cert-name ${domain} --force-renewal && cp -L ${LETSENCRYPT_DIR}/${domain}/fullchain.pem ${CERTS_DIR}/${domain}/fullchain.pem && cp -L ${LETSENCRYPT_DIR}/${domain}/privkey.pem ${CERTS_DIR}/${domain}/privkey.pem && docker start ${NGINX_CONTAINER_NAME}' # ${marker}"
    
    (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
    
    echo "Автообновление SSL-сертификата для $domain настроено (@monthly)."
    return 0
}

remove_auto_renew() {
    local domain=$1
    local marker="vpnbot_auto_renew_${domain}"
    
    echo "Удаляем автообновление SSL-сертификата для $domain..."
    
    if crontab -l 2>/dev/null | grep -q "$marker"; then
        (crontab -l 2>/dev/null | grep -v "$marker") | crontab -
        echo "Автообновление SSL-сертификата для $domain успешно удалено!"
    else
        echo "Автообновление SSL-сертификата для $domain не найдено."
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
    echo "3) Добавить конфигурацию с сайтом в include.conf"
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
                read -rp "IP и порт сервиса (например: 123.123.123.123:9000): " service_ip                
                manage_nginx stop
                issue_cert "$domain" && copy_cert "$domain"
                install_site "$domain" "$service_ip"
                enable_auto_renew "$domain"
                manage_nginx start
                ;;
            2)
                read -rp "Домен (например: sub.example.com): " domain
                manage_nginx stop
                issue_cert "$domain" && copy_cert "$domain"
                manage_nginx start
                ;;
            3)
                read -rp "Домен (например: sub.example.com): " domain
                read -rp "IP и порт сервиса (например: 123.123.123.123:9000): " service_ip
                install_site "$domain" "$service_ip" && manage_nginx restart
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
                manage_nginx restart
                ;;
            6)
                read -rp "Домен (например: sub.example.com): " domain
                remove_cert "$domain"
                ;;
            7)
                read -rp "Домен (например: sub.example.com): " domain
                remove_site "$domain" && manage_nginx restart
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
