# nginx → Consul DNS discovery (Блок 3.2)

**Дата:** 2026-06-21
**Статус:** дизайн узгоджено, план не написано

## Проблема

nginx-апстріми зараз — захардкоджені IP `groups[...][0]` (один хост, нуль фейловера),
обчислені в `roles/nginx/defaults/main.yml` і вписані в завантажений Webitel-конфіг
`replace`-тасками. До того ж навіть якби вписати `*.service.consul` літералом —
nginx із `proxy_pass http://name:port` резолвить DNS **один раз на старті й кешує
назавжди**. Якщо нода впаде, nginx не перепідключиться, поки не reload.

Мета: апстріми через Consul DNS із **runtime-резолвом** (фейловер без reload).

## Узгоджені рішення

- **Патчимо shipped Webitel-конфіг** (не власний шаблон). Точні regexp-патчі
  залежать від реальної структури shipped 26.4 default (літерали `127.0.0.1:PORT`
  vs уже-`$backend`-змінні) — фіналізуються після надання shipped-конфіга.
- **Resolver:** `127.0.0.1:8600` напряму в Consul DNS (`valid=3s`) — як у робочому
  reference-конфізі й консистентно з HAProxy; незалежно від dnsmasq.
- **Prepared queries** для `webitel-api`/`webitel-messages-bot` — **створюємо** в
  consul-ролі (go-micro реєструє під DNS-недружніми іменами `go.webitel.api` /
  `webitel.chat.bot`; query дає чистий alias + OnlyPassing).
- **opensips, grafana** — реєструються майбутніми **nomad-джобами** (окрема сесія).
  Цей плейбук їх НЕ реєструє, лише посилається на їхні `.consul`-імена.

## Backend-імена

| Апстрім | Порт | Consul-імʼя | Тип / джерело реєстрації |
|---|---|---|---|
| storage | `webitel_storage_public_port` (10037) | `storage.service.consul` | service, Go self-reg |
| api/core | 8080 | `webitel-api.query.consul` | prepared query → `go.webitel.api` |
| messages bot | `webitel_messages_bot_port` (10040) | `webitel-messages-bot.query.consul` | prepared query → `webitel.chat.bot` |
| engine WS | `webitel_engine_websocket_port` (10031) | `engine.service.consul` | service, Go self-reg |
| opensips | 5070 | `opensips.service.consul` | nomad-джоба (майбутнє) |
| grafana | 3000 | `grafana.service.consul` | nomad-джоба (майбутнє) |

## nginx — механізм (тільки multi-host; single_node лишається на 127.0.0.1)

Shipped 26.4 default — на літералах `127.0.0.1:PORT` у `proxy_pass` (+ два http-level
`map`). Наявні `replace`-таски їх матчать. Підхід:

### 1. Дефолти emit `$backend` (multi) / `127.0.0.1` (single)
У `roles/nginx/defaults/main.yml` змінити 5 upstream-дефолтів, щоб видавали імʼя
nginx-змінної замість IP (grafana лишається IP — через nomad later):

```yaml
nginx_upstream_storage:    "{{ '127.0.0.1' if single_node else '$storage_backend' }}"
nginx_upstream_api:        "{{ '127.0.0.1' if single_node else '$webitel_api_backend' }}"
nginx_upstream_messages:   "{{ '127.0.0.1' if single_node else '$messages_bot_backend' }}"
nginx_upstream_engine_ws:  "{{ '127.0.0.1' if single_node else '$engine_backend' }}"
nginx_upstream_opensips:   "{{ '127.0.0.1' if single_node else '$opensips_backend' }}"
# nginx_upstream_grafana — без змін (IP-based; grafana через nomad-джобу пізніше)
```

Наявні `replace`-таски вже вставляють `{{ nginx_upstream_X }}:{{ port }}` → отримуємо
`$storage_backend:10037` тощо. Таски майже не міняються; api/opensips зберігають
`when: not single_node` (single → лишається `127.0.0.1`).

### 2. Інʼєкція resolver + map (blockinfile у sites-enabled/default, BOF)
`map`/`resolver` — http-рівень. Інжектимо на **початок** `sites-enabled/default`
(той самий файл, що вже містить http-level `map` → гарантовано в http-контексті,
без conf.d-припущень). `blockinfile` з маркерами, ідемпотентно, `when: not single_node`:

```nginx
resolver 127.0.0.1:8600 valid=3s ipv6=off;
map $host $webitel_api_backend   { default webitel-api.query.consul; }
map $host $storage_backend       { default storage.service.consul; }
map $host $messages_bot_backend  { default webitel-messages-bot.query.consul; }
map $host $engine_backend        { default engine.service.consul; }
map $host $opensips_backend      { default opensips.service.consul; }
```

`proxy_pass` зі змінною → runtime-резолв через `resolver` (`valid=3s` → фейловер без
reload). Існуючий `map $request_method $api_backend` патчиться на
`"$webitel_api_backend:8080"` / `"$storage_backend:10037"` (map значення інтерполює
змінні — підтверджено робочим reference).

### Порт-мапінг (Webitel-дефолт → wansible-порт)
| Апстрім | shipped | $backend:порт |
|---|---|---|
| storage | 10023 | `$storage_backend:{{ webitel_storage_public_port }}` (10037) |
| api | 8080 | `$webitel_api_backend:8080` |
| messages bot | 10031 | `$messages_bot_backend:{{ webitel_messages_bot_port }}` (10040) |
| engine WS | 10022 | `$engine_backend:{{ webitel_engine_websocket_port }}` (10031) |
| opensips | 5070 | `$opensips_backend:5070` |
| grafana | 3000 | (IP, без змін) |
| portal grpc | 10028 | (127.0.0.1, без змін) |

### single_node
Без змін — літеральні `127.0.0.1:PORT`. blockinfile і `$var`-дефолти — лише
`when: not single_node`. Підтвердження валідності — `nginx -t` (validate).

## consul-роль — prepared queries

Ідемпотентне створення (POST не ідемпотентний — спершу GET):

```
GET  http://127.0.0.1:8500/v1/query            → список (register)
# якщо нема query з потрібним Name:
POST http://127.0.0.1:8500/v1/query  {"Name": "...", "Service": {"Service": "...", "OnlyPassing": true}}
```

Дві черги:
- `webitel-api` → service `go.webitel.api`, OnlyPassing
- `webitel-messages-bot` → service `webitel.chat.bot`, OnlyPassing

Створюються один раз (run_once на consul_server-ноді). Реалізація: `ansible.builtin.uri`.

## Нюанси (не блокери)

- **api co-location:** `go.webitel.api` слухає захардкоджено `127.0.0.1:8080` (PENDING
  у `core.yml` — listen-адреса не винесена в env). Тож `webitel-api.query` дасть
  `127.0.0.1` → nginx має бути на тій самій ноді, що core (так і є у failover.example).
- **opensips/grafana** резолвляться лише після появи відповідних nomad-джоб; до того
  ці апстріми down (свідомо, узгоджено).

## Поза скоупом

- Consul-реєстрація opensips і grafana (nomad-джоби, окрема сесія).
- Винесення api/app listen-адреси в env (upstream PENDING).
- single_node перехід на Consul (лишається 127.0.0.1).
