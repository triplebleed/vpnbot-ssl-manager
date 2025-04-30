![screenshot](https://hostux.pics/images/2025/04/15/imaged370a45bba17a530.png)

---

## Запуск скрипта

Для запуска скрипта выполните команду в терминале:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/triplebleed/vpnbot-ssl-manager/main/vpnbot-ssl-manager.sh)"
```

--- 

## Руководство по правильному созданию контейнеров

Для повышения безопасности рекомендуем запускать ваши сервисы внутри Docker-сети `vpnbot_default` и не публиковать их порты наружу. Используйте статические IP-адреса из диапазона от **`10.10.0.16`** до **`10.10.0.255`**, чтобы избежать пересечений с сервисами vpnbot.

#### Пример создания контейнера Uptime Kuma

```docker
docker run -d \
  --name uptime-kuma \
  --restart unless-stopped \
  --network vpnbot_default \
  --ip 10.10.0.22 \
  -v uptime-kuma_data:/app/data \
  louislam/uptime-kuma:1
```

- `--network vpnbot_default` — подключает контейнер к сети `vpnbot_default`.
- `--ip 10.10.0.22` — статический адрес из свободного пула.
- **Без** опции `-p` или `--expose`, чтобы порт 3001 не «светился» на хосте.

- Для указания домена в меню (операция 3) введите `uptime-kuma:3001`, где:
    - `uptime-kuma` — имя контейнера.
    - `3001` — внутренний порт приложения (проверьте через `docker inspect uptime-kuma --format '{{range $p, $_ := .Config.ExposedPorts}}{{$p}}{{end}}'`).

Таким образом ваши приложения будут недоступны напрямую из вне, и весь внешний трафик пройдет через контейнер nginx, обеспечивая централизованную маршрутизацию и SSL.
