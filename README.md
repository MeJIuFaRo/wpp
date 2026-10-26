# WEB PANEL PROXY 2.3.6 в Docker

Docker-образы панели [web-panel-proxy](https://github.com/POLESNIESOVETI12/web-panel-proxy) 2.3.6 с доработками:

- общий MTProto на 8443/tcp, до 64 ключей; панель допускает до 128 профилей;
- WEB-клиент добавляется без перезапуска relay и чужих соединений;
- лимит профилей WEB-relay — 128;
- точный учёт трафика без nftables: WEB — по профилям в relay, MTProto — по каждому ключу на общем 8443 (MTProxy считает байты клиентских соединений).

Протоколы: WEB Proxy, MTProto, VLESS XHTTP, Hysteria2, OpenFlux. Управление — через веб-панель, как раньше.

## Образы

| Образ | Содержимое |
|---|---|
| `mejiufaro/wpp-panel` | панель, менеджер клиентов, периодические задачи |
| `mejiufaro/wpp-relay` | WEB-relay (tproxy-server) |
| `mejiufaro/wpp-mtproxy` | MTProxy: backend'ы WEB-клиентов и общий MTProto |
| `mejiufaro/wpp-xray` | Xray: VLESS XHTTP и Hysteria2 |
| `mejiufaro/wpp-openflux` | OpenFlux |
| `caddy:2.11.4` | HTTPS, официальный образ |

Все контейнеры работают от UID 10000, без root и без capabilities, с файловой системой только для чтения. Они делят одно сетевое пространство (как pod) и общаются через 127.0.0.1, как службы на VPS.

## Развёртывание

Требования: x86_64, Docker с Compose v2, домен с A-записью на сервер (или проброс 80/443 на него), свободные порты 80/tcp, 443/tcp, 8443/tcp, 8443/udp.

```bash
mkdir -p /opt/wpp && cd /opt/wpp
# скопировать сюда содержимое каталога deploy/
./install.sh            # создаст .env из шаблона
nano .env               # WPP_DOMAIN; при необходимости WPP_PUBLIC_HOST и WPP_ACME_EMAIL
./install.sh            # создаст config/ и data/ с правами для UID 10000
docker compose up -d
docker compose logs panel   # адрес панели, логин и пароль (один раз)
```

Если пароль в `.env` не задан, он генерируется, печатается в логе и сохраняется в `data/panel/initial-admin-password`. После первого входа удалите этот файл; пароль из `.env` тоже лучше убрать.

## Где что лежит

| Каталог | Содержимое |
|---|---|
| `config/panel` | секреты панели, клиенты (`users.json`), адрес панели (`panel.env`), OpenFlux |
| `config/units` | unit-файлы служб клиентов, которые пишет панель |
| `config/relay`, `config/mtproxy`, `config/xray`, `config/caddy`, `config/site` | конфигурация служб и сайт-заглушка |
| `config/control` | токен агентов и состояние служб |
| `data/panel` | данные панели, трафик, метрики |
| `data/caddy` | сертификаты Let's Encrypt |

Резервная копия — весь каталог развёртывания (`config`, `data`, `.env`, `docker-compose.yaml`). Восстановление на другом сервере: скопировать каталог и выполнить `docker compose up -d`.

Значения из `.env` используются только при первом запуске; дальше действуют сохранённые в `config/`. Для смены домена нужен новый каталог развёртывания.

## Обновление

```bash
cd /opt/wpp
# при необходимости поменять WPP_TAG в .env
docker compose pull && docker compose up -d
```

Кнопка обновления в панели в Docker отключена.

## Диагностика

```bash
docker compose ps
docker compose logs -f panel relay backends mtproto xray
docker compose exec panel systemctl status tproxy-server
docker compose exec panel journalctl -u web-panel-proxy-mtproto -n 50
docker compose exec panel web-proxy-panelctl users
```

`systemctl` и `journalctl` внутри контейнера панели — совместимая замена: команды уходят агенту контейнера, которому принадлежит служба.

## Сборка

```bash
scripts/build.sh build          # все образы по очереди
tests/smoke-relay.sh mejiufaro/wpp-relay:2.3.6-5
tests/smoke-mtproxy.sh mejiufaro/wpp-mtproxy:2.3.6-5
tests/integration.sh            # весь стек без публичного домена
scripts/build.sh push 2.3.6-5-rc   # проверка на секреты и публикация
```

Исходники upstream закреплены по коммитам и контрольным суммам в `versions.env`. Доработки — патчи в `src/relay-patches` и `src/mtproxy-patches`; код панели — в `src/panel` (исходное состояние до переноса в Docker — в `reference/2.3.6/panel` для сравнения). Устройство и принятые решения — в [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
