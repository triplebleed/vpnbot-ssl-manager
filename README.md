## 🛡️ VPNBOT SSL MANAGER

![screenshot](https://hostux.pics/images/2025/05/21/image5ec8d492170576fe.png)

## 🚀 Быстрый старт

Выполните следующую команду в терминале:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/triplebleed/vpnbot-ssl-manager/main/vpnbot-ssl-manager.sh)"
```

## 🐳 Запуск Docker-контейнеров

Для максимальной защиты размещайте ваши сервисы внутри Docker-сети `vpnbot_default` без прямого выхода во внешнюю сеть:

- Используйте статические IP-адреса из диапазона **`10.10.0.16`** - **`10.10.0.255`**, чтобы не было конфликтов с контейнерами vpnbot'а
- Не публикуйте порты наружу через опцию `-p`
- Весь внешний трафик будет проходить через защищенный nginx-прокси

#### Пример конфигурации: Uptime Kuma

```bash
docker run -d \
  --name uptime-kuma \
  --restart unless-stopped \
  --network vpnbot_default \
  --ip 10.10.0.22 \
  -v uptime-kuma_data:/app/data \
  louislam/uptime-kuma:1
```

В качестве адреса в меню (операция 3) укажите `uptime-kuma:3001`, где:
- `uptime-kuma` — имя Docker-контейнера
- `3001` — внутренний порт приложения

Для определения внутреннего порта контейнера:

```bash
docker inspect uptime-kuma --format '{{range $p, $_ := .Config.ExposedPorts}}{{$p}}{{end}}'
```

Таким образом ваши приложения будут недоступны напрямую из вне, и весь внешний трафик пройдет через контейнер nginx, обеспечивая централизованную маршрутизацию и SSL
