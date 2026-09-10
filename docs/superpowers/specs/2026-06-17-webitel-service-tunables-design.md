# Webitel service tunables — design

**Дата:** 2026-06-17
**Гілка:** feat/patroni-warm-standby-2dc
**Статус:** design approved, очікує написання плану

## Мета

Зробити webitel-сервіси конфігурованими через **типізовані namespaced vars** замість
редагування нутрощів ролі або дампу повного env. Головний драйвер — **firewall/проксі
вимагають фіксованих портів**: частина сервісів (engine, call_center, storage,
flow_manager) зараз слухають gRPC на `GRPC_PORT=0` (рандомний порт), що неможливо
відкрити у firewall детерміновано.

Окрім портів — DSN-тюнінг (sslmode / connect_timeout / heartbeat), log level і
service-specific параметри (storage media/temp directory, call_center omnichannel).

## Контекст (поточна модель)

- Конфіг кожного сервісу — у `roles/webitel_service/vars/services/<name>.yml`
  (`webitel_service_spec.env`). Вантажиться через `include_vars` → **дуже високий
  precedence**, вищий за group_vars. Прямий override з group_vars неможливий.
- Єдиний override-важіль сьогодні — `webitel_service_env_extra` (один глобальний dict
  у `defaults/`), `combine` поверх `spec.env`. Не масштабується на per-service knob-и
  і вимагає від користувача знати точні env-ключі.

## Звірка з upstream (origin/v26.04 `.env.example` + сорси)

Дві форми задання порту співіснують у наборі:

| Сервіс | gRPC-механізм | Поточний дефолт | Інші endpoint-и |
|---|---|---|---|
| engine | окремий `GRPC_PORT` | `0` (рандом) | `WEBSOCKET=:80` |
| call_center | окремий `GRPC_PORT` | `0` (рандом) | — |
| storage | окремий `GRPC_PORT` | `0` (рандом) | `PUBLIC_ADDRESS`/`INTERNAL_ADDRESS` (commented) |
| flow_manager | окремий `GRPC_PORT` | `0` (рандом) | `WEB_ADDR=:5689` |
| cases | inline `GRPC_ADDR=addr:port` | `22103` | — |
| logger | inline `GRPC_ADDR=addr:port` | `10011` | — |
| media_exporter | inline `GRPC_ADDR=addr:port` | `22500` | — |
| messages | inline | `MICRO_SERVICE_ADDRESS=:0`, `WEBITEL_BOT_ADDRESS=:10030` | — |
| core (api/app) | захардкоджено в юнітах | — | **PENDING upstream** |

Log level env-ключ теж різний:
- `LOG_LVL` — engine, call_center, storage, flow_manager (дефолт `debug`)
- `WBTL_LOG_LEVEL` — messages (дефолт `info`)
- `MICRO_LOG_LEVEL` — core (дефолт `trace`)
- logger, cases, media_exporter — env-ключа log level **немає** → knob не додаємо

Service-specific (звірено в `.env.example`):
- storage: `MEDIA_DIRECTORY=/opt/storage/data`, `TEMP_DIRECTORY=/var/lib/webitel/storage-temp`
- call_center: `ENABLE_OMNICHANNEL=0`

## Рішення

### 1. Механізм override

Пласкі namespaced vars `webitel_<service>_<param>`, які читаються **всередині**
`vars/services/<name>.yml` через `{{ webitel_<svc>_<param> | default(<baked-default>) }}`.

- Baked-default = поточна/upstream-поведінка. Без явного override **нічого не
  змінюється**.
- Користувач задає override у `group_vars/all` (на весь кластер) або у `host_vars` /
  group_vars сервіс-групи (на хост).
- Той самий precedence-патерн, що вже скрізь у репо (`external_* if defined else …`,
  `var | default(…)`). Жодного нового фреймворку.
- `webitel_service_env_extra` лишається без змін як escape-hatch для рідкісних
  ключів, які не виправдовують окремого knob-а.

Чому не вкладені dict-и (`webitel_engine: {…}`): часткові override через `combine`
у Ansible незручні й менш прозорі; решта репо — пласка (`webitel_pg_host`,
`webitel_engine_env_file`).

### 2. Порти

**УСІ** listener-и сервісів (не лише gRPC) зводяться в **єдиний неперервний блок
10030–10043** — firewall відкриває один діапазон. Дефолти більше не `0`/розкидані/
upstream-плейсхолдери — кожен listener має детермінований порт. Порядок — згрупований
по сервісах у послідовності `known_services`.

| # | Сервіс | listener | env-ключ | knob | порт | nginx |
|---|---|---|---|---|---|---|
| 1 | engine | gRPC | `GRPC_PORT` (окремий) | `webitel_engine_grpc_port` | 10030 | |
| 2 | engine | WebSocket | `WEBSOCKET` | `webitel_engine_websocket_port` | 10031 | ✓ |
| 3 | call_center | gRPC | `GRPC_PORT` (окремий) | `webitel_call_center_grpc_port` | 10032 | |
| 4 | flow_manager | gRPC | `GRPC_PORT` (окремий) | `webitel_flow_manager_grpc_port` | 10033 | |
| 5 | flow_manager | web | `WEB_ADDR` | `webitel_flow_manager_web_port` | 10034 | |
| 6 | flow_manager | ESL | `ELSE_PORT` | `webitel_flow_manager_esl_port` | 10035 | |
| 7 | storage | gRPC | `GRPC_PORT` (окремий) | `webitel_storage_grpc_port` | 10036 | |
| 8 | storage | public HTTP | `PUBLIC_ADDRESS` | `webitel_storage_public_port` | 10037 | ✓ |
| 9 | storage | internal HTTP | `INTERNAL_ADDRESS` | `webitel_storage_internal_port` | 10038 | |
| 10 | messages | gRPC | `MICRO_SERVICE_ADDRESS` | `webitel_messages_service_port` | 10039 | |
| 11 | messages | bot HTTP | `WEBITEL_BOT_ADDRESS` | `webitel_messages_bot_port` | 10040 | ✓ |
| 12 | logger | gRPC | `GRPC_ADDR` (inline) | `webitel_logger_grpc_port` | 10041 | |
| 13 | cases | gRPC | `GRPC_ADDR` (inline) | `webitel_cases_grpc_port` | 10042 | |
| 14 | media_exporter | gRPC | `GRPC_ADDR` (inline) | `webitel_media_exporter_grpc_port` | 10043 | |

Колонка **nginx ✓** — listener, на який проксує shipped nginx-конфіг → порт мусить
матчитись з обох сторін (див. §6).

Форми рендеру в env:
- Окремий порт (`GRPC_PORT`): `GRPC_PORT={{ webitel_<svc>_grpc_port | default(<N>) }}`.
- Лише порт (`WEBSOCKET`, `PUBLIC_ADDRESS`, `INTERNAL_ADDRESS`, `ELSE_PORT`):
  `<KEY>=:{{ webitel_<svc>_<x>_port | default(<N>) }}` (bind на всі інтерфейси — як upstream).
- Inline `addr:port` (`GRPC_ADDR`, `WEB_ADDR`, `MICRO_SERVICE_ADDRESS`, `WEBITEL_BOT_ADDRESS`):
  `<KEY>={{ _addr }}:{{ webitel_<svc>_<x>_port | default(<N>) }}`.

Нотатки:
- engine `GRPC_PORT` у поточному spec відсутній — **додається**.
- gRPC engine/call_center/storage/flow_manager: upstream-дефолт `0` (random) → стає
  фіксованим (10030/10032/10033/10036). logger/cases/media_exporter: змінюються з
  10011/22103/22500 на 10041/10042/10043.
- engine WS (10031), storage public (10037), messages bot (10040) — упстрім/shipped-nginx
  чекали 10022/10023/10031; renumber їх вимагає синхронної правки nginx (§6).
- Bind-адреса лишається авто-похідною (`127.0.0.1` для `single_node`, інакше
  `default_ipv4`) — не виносимо в knob (поза скоупом).

### 3. DSN / AMQP тюнінг (дворівнево: кластер → сервіс)

Cross-cutting дефолти живуть у `roles/topology/defaults` (як решта глобалів),
per-service override перебиває:

- `webitel_<svc>_pg_sslmode | default(webitel_pg_sslmode)` — `webitel_pg_sslmode`
  baked-default `disable`.
- `webitel_<svc>_pg_connect_timeout | default(webitel_pg_connect_timeout)` — default `10`.
- `webitel_<svc>_amqp_heartbeat | default(webitel_amqp_heartbeat)` — default `10`.

Тобто `sslmode=require` вмикається один раз на весь кластер, але перебивається на
конкретний сервіс. **`search_path` лишається зашитим** (явне рішення користувача —
це не тюнабельний параметр, а контракт схеми).

### 4. Log level (дворівнево)

`webitel_<svc>_log_level | default(webitel_log_level)`, де `webitel_log_level` —
кластерний default у `roles/topology/defaults`. Рендериться у правильний env-ключ
сервісу (`LOG_LVL` / `WBTL_LOG_LEVEL` / `MICRO_LOG_LEVEL`). Сервіси без log-ключа
(logger, cases, media_exporter) knob не отримують.

Baked-default кластерного `webitel_log_level`: лишити поточну поведінку. Оскільки
upstream-дефолти різні (`debug`/`info`/`trace`), кластерний knob ставиться **тільки
коли заданий явно**: `webitel_<svc>_log_level | default(webitel_log_level | default(<upstream>))` —
тобто якщо ні per-service, ні кластерний не задані, лишається upstream-дефолт сервісу.

### 5. Service-specific

- storage: `webitel_storage_media_directory` (default `/opt/storage/data`),
  `webitel_storage_temp_directory` (default `/var/lib/webitel/storage-temp`).
- call_center: `webitel_call_center_omnichannel` (default `0`) → `ENABLE_OMNICHANNEL`.
- Будь-який наступний специфічний параметр додається тим самим патерном.

### 6. nginx-інтеграція (порти proxied-listener-ів)

Shipped nginx-конфіг (`/etc/nginx/sites-enabled/default`, качається `get_url`-ом)
**хардкодить порти upstream-ів**, а `roles/nginx/tasks/configure.yml` зараз переписує
лише **хост** (`127.0.0.1` → IP) і **лише `when: not single_node`**. Оскільки ми
renumber-имо порти, nginx має брати їх з тих самих knob-ів — інакше проксі ламається.

Три webitel_service-listener-и, на які проксує nginx (решта — opensips/grafana/api —
поза скоупом цього spec):

| nginx upstream | shipped-порт | новий порт | knob (єдине джерело) |
|---|---|---|---|
| engine WS (`nginx_upstream_engine_ws`) | 10022 | 10031 | `webitel_engine_websocket_port` |
| storage (`nginx_upstream_storage`) | 10023 | 10037 | `webitel_storage_public_port` |
| messages (`nginx_upstream_messages`) | 10031 | 10040 | `webitel_messages_bot_port` |

Зміни в `roles/nginx`:
- `replace`-таски переписують **і хост, і порт** (regexp захоплює shipped-порт, replace
  підставляє `{{ knob }}`), а не лише хост.
- Прибрати `when: not single_node` для цих трьох — на single-host порт теж міняється
  (хост лишається `127.0.0.1`), бо сервіс уже не слухає shipped-дефолт.
- knob-и читаються напряму (той самий `webitel_<svc>_<x>_port | default(<N>)`), щоб
  значення гарантовано збігалося з тим, що виставив `webitel_service` у env. Єдине
  джерело істини — knob; nginx його лише споживає.
- ⚠️ Залежність порядку: nginx configure має йти **після** того, як знає порти (вони —
  pure defaults/knob-и, не facts сервіс-хостів), тож проблеми крос-хост немає; але звірити
  в `web.yml`, що змінні доступні на nginx-хості.

### 7. Документація

- Закоментовані приклади knob-ів у `inventories/multihost.example/group_vars/all/main.yml`
  (як зроблено для proxy-інпутів) — згруповані по сервісах, з дефолтами.
- Оновити `roles/webitel_service/README.md` — таблиця доступних knob-ів per-сервіс +
  повна port-мапа блоку 10030–10043.

## Non-goals

- Порти core `api`/`app` (nginx `:8080`) — захардкоджені в юнітах, чекають upstream
  (PENDING). Поза скоупом — nginx-таск для api лишаємо як є.
- nginx upstream-и opensips (`:5070`) / grafana (`:3000`) — не webitel_service, не чіпаємо.
- Похідний firewall-список портів / окрема firewall-роль — не зараз (рішення користувача).
- Вкладені dict-и, валідація діапазону портів у preflight — YAGNI, поки не треба.

## Ризики / залежності

- **Зміна default-поведінки свідома й широка:** усі listener-порти перенумеровані в блок
  10030–10043. Це і є мета (firewall + детермінізм). Наслідок — наявні інсталяції мусять
  оновити firewall-правила; задокументувати в changelog/README.
- **Двостороння синхронність nginx↔сервіс.** Якщо knob змінено, а nginx-таск не оновив
  порт (або навпаки) — проксі мовчки ламається. Тому порт обох сторін береться з ОДНОГО
  knob. Покрити перевіркою на VM (engine WS, storage download/upload, chat-віджет).
- **Колізії на single-host.** Усі 14 listener-ів можуть слухати `127.0.0.1` одночасно →
  блок 10030–10043 унікальний за побудовою. Звірити, що нема перетину з іншими портами на
  хості (consul 8500, pg 5432/6432/6433, rabbitmq 5672, opensips, freeswitch тощо —
  поза блоком, але перевірити).
- **Точні env-ключі звірені з origin/v26.04 на 2026-06-17.** Перед merge перевірити на
  VM, що `lineinfile` потрапляє в реальні ключі (особливо log level — ключ різниться;
  `GRPC_PORT` як окремий ключ в engine; `ELSE_PORT`/`MICRO_SERVICE_ADDRESS` — що бінарі їх
  читають як listener-и, а не клієнти).
- **storage `PUBLIC_ADDRESS`/`INTERNAL_ADDRESS`** у `.env.example` закоментовані — додаємо
  ключі явно; перевірити, що бінар їх читає (а не лише зашитий дефолт).
