# HAProxy як балансувальник перед Patroni (PostgreSQL)

- **Дата:** 2026-06-12
- **Статус:** Draft (на рев'ю)
- **Репо:** wansible
- **Джерела:** референс `patroni-cluster/patroni/haproxy.sh` (bash); сорси сервісів (`flow_manager`, `engine`, `call_center`, `storage`, `webitel.go`); spec [2026-06-10-webitel-26.4-redesign](2026-06-10-webitel-26.4-redesign-design.md)

## 1. Контекст і мотивація

Зараз доступ сервісів до PostgreSQL іде через єдину змінну `webitel_pg_host` (group_vars/all), порт `:5432` захардкоджено всередині `webitel_pg_dsn_base`. У HA-режимі (є `groups['patroni']`) `webitel_pg_host` резолвиться у `master.<scope>.service.consul` — тобто виявлення лідера зараз робить Consul DNS + health-check Patroni.

Проблема DNS-підходу: TTL/кешування на клієнтах сповільнює failover, немає read/write-split, немає окремого endpoint для реплік.

**Рішення:** ввести HAProxy перед Patroni-кластером з двома портами — leader (rw) і replicas (ro), з health-check'ами через Patroni REST. `webitel_pg_host` починає вказувати на HAProxy, а сервіси, що вміють читати з реплік, отримують окремий ro-DSN.

## 2. Ухвалені рішення (з обговорення)

1. **Топологія конфігурується через наявну `services`-модель**, без нових прапорців: нова service-група `haproxy`. **Sidecar** = `haproxy` у `services` кожного app-хоста (підключення по `127.0.0.1`); **dedicated** = `haproxy` на одному виділеному хості (сервіси ходять на його IP). Sidecar — рекомендований режим (без SPOF, узгоджено з кластеризованими Consul/RabbitMQ/Patroni).
2. **Два порти, єдина схема всюди: rw `6432`, ro `6433`** (конфігуровані). Окрема від `5432`/`5433` схема обрана свідомо, бо у HA-прикладах Patroni co-located з сервісами (ha1/ha2/ha3 одночасно `patroni` + webitel), і Patroni вже слухає `127.0.0.1:5432` — sidecar-HAProxy не може взяти 5432.
3. **rw → `GET /master` (expect 200); ro → `GET /replica`, `balance roundrobin`** (як у референсі). `mode tcp`.
4. **TLS до Patroni REST лише коли `patroni_tls_enabled`** (`check-ssl` + клієнтський бандл + `ca-file`); інакше plain-http чек на `:8008`. Сертифікати видає наявна `pki`-роль.
5. **Реплік-DSN вайриться лише у сервіси, що його підтримують** (перевірено у сорсах): `engine`, `call_center`, `flow_manager`, `storage` — через env `SQL_DATA_SOURCE_REPLICAS`. Решта (`core`, `logger`, `cases`, `media_exporter`, `messages`, `opensips`, `grafana`) — лише rw.
6. **keepalived/VIP для HA виділеного HAProxy — поза скоупом** (наступний етап, в дусі phased-підходу). Dedicated-режим поки бере `groups['haproxy'][0]` без VIP.

## 3. Нова роль `haproxy`

Структура як у решти ролей (плоска, snake_case, FQCN):

```
roles/haproxy/
  defaults/main.yml
  tasks/main.yml
  tasks/install.yml
  tasks/configure.yml
  templates/haproxy.cfg.j2
  handlers/main.yml
  README.md
```

### 3.1 `install.yml`
- keyring `haproxy-archive-keyring.gpg` з `haproxy.debian.net` (по аналогії з keyring-патернами postgres/patroni ролей; без proxy — той у референсі специфічний для банку).
- APT-репо `deb [signed-by=…] http://haproxy.debian.net <codename>-backports-<branch> main`, гілка через `haproxy_apt_branch` (дефолт `3.2`).
- пакет `haproxy`.

### 3.2 `configure.yml`
- Коли `patroni_tls_enabled`: зібрати клієнтський бандл (`peer-<host>.pem` + `peer-<host>-key.pem` → `peer-<host>-bundle.pem`, `0644`) з `pki_remote_dir`.
- Шаблон `/etc/haproxy/haproxy.cfg` (notify reload).
- enable сервісу.

### 3.3 `templates/haproxy.cfg.j2`
- `global` / `defaults` (mode tcp, tcplog, retries/timeouts як у референсі).
- `listen postgres-rw`: `bind {{ haproxy_bind_addr }}:{{ haproxy_pg_rw_port }}`, `option httpchk GET /master`, `http-check expect status 200`, бекенди.
- `listen postgres-ro`: `bind {{ haproxy_bind_addr }}:{{ haproxy_pg_ro_port }}`, `option httpchk GET /replica`, `balance roundrobin`, бекенди.
- `listen prometheus-metrics` (опційно, `haproxy_metrics_enabled`): `bind 127.0.0.1:{{ haproxy_metrics_port }}`, `mode http`, prometheus-exporter на `/metrics`.

Бекенд-сервери (для обох listen) генеруються з `haproxy_backends`:
```
server <name> <ip>:5432 check port 8008 weight <weight> {% if patroni_tls_enabled %}check-ssl crt <bundle> ca-file <ca>{% endif %} inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
```

### 3.4 `defaults/main.yml`
```yaml
haproxy_apt_branch: "3.2"
haproxy_pg_rw_port: 6432
haproxy_pg_ro_port: 6433
# 0.0.0.0 коректно і для sidecar (доступ по 127.0.0.1), і для dedicated (доступ
# по IP ноди іншими хостами). Колізії з Patroni:5432 немає — порти інші. Звуження
# до конкретної адреси — через override у group_vars, мережа/firewall за бажанням.
haproxy_bind_addr: "0.0.0.0"
# Бекенди = Patroni-ноди поточного ДЦ (фільтр як patroni_cluster_hosts)
haproxy_backends: >-
  {{ (patroni_cluster_hosts | default(groups['patroni'] | default([])))
     | map('extract', hostvars)
     | map(attribute='inventory_hostname') | list }}
haproxy_tls_enabled: "{{ patroni_tls_enabled | default(false) }}"
haproxy_ssl_dir: "{{ pki_remote_dir | default('/etc/ssl/app') }}"
haproxy_metrics_enabled: false
haproxy_metrics_port: 8405
```
Вага сервера = `hostvars[host].patroni_priority | default(1)` (вже використовується для failover-пріоритету).

### 3.5 `handlers/main.yml`
- `reload haproxy` (`systemctl reload haproxy`; для зміни binds — restart).

## 4. Активація та виявлення endpoint

### 4.1 Інвентар
- `00-service-groups.yml`: додати порожню групу `haproxy`.
- Хости отримують `haproxy` у своєму `services` (constructed plugin створює групу `haproxy`).
  - **sidecar**: `haproxy` у кожного app-хоста (у failover-прикладі — ha1/ha2/ha3).
  - **dedicated**: `haproxy` на одному хості.
- `pki`-роль: переконатися, що haproxy-хости входять у scope видачі сертифікатів (потрібен `peer-<host>` cert для `check-ssl`).

### 4.2 `webitel_pg_host` (host-aware, group_vars/all)
Оновити існуючий вираз:
```yaml
webitel_pg_host: >-
  {{ '127.0.0.1' if inventory_hostname in (groups['haproxy'] | default([]))
     else (hostvars[groups['haproxy'][0]].ansible_default_ipv4.address
           if (groups['haproxy'] | default([])) | length > 0
           else (('master.' + webitel_patroni_scope + '.service.consul') if ha_mode
                 else ('127.0.0.1' if single_node
                       else hostvars[groups['postgres'][0]].ansible_default_ipv4.address))) }}
```

### 4.3 Порти і DSN (group_vars/all)
```yaml
webitel_pg_haproxy: "{{ (groups['haproxy'] | default([])) | length > 0 }}"
webitel_pg_port: "{{ haproxy_pg_rw_port if webitel_pg_haproxy else 5432 }}"
webitel_pg_dsn_base: "postgres://opensips:webitel@{{ webitel_pg_host }}:{{ webitel_pg_port }}/webitel"
# ro-endpoint: той самий хост, порт реплік; без haproxy = rw
webitel_pg_dsn_replicas: >-
  {{ ('postgres://opensips:webitel@' + webitel_pg_host + ':' + (haproxy_pg_ro_port | string) + '/webitel')
     if webitel_pg_haproxy else webitel_pg_dsn_base }}
```
`haproxy_pg_rw_port` / `haproxy_pg_ro_port` мають бути доступні на рівні group_vars (продублювати дефолти або винести у group_vars/all, щоб не залежати від ролі при обчисленні DSN).

### 4.4 Споживачі
- **opensips** (`tasks/configure.yml`): regex наразі хардкодить `:5432` —
  `regexp: '(postgres://opensips:webitel@)[^:]*(:\d+)'`, `replace: '\1{{ webitel_pg_host }}:{{ webitel_pg_port }}'` (опенсіпс пише в БД → rw).
- **grafana** (`tasks/configure.yml`): `url: "{{ webitel_pg_host }}:{{ webitel_pg_port }}"`.
- **Реплік-DSN** (`SQL_DATA_SOURCE_REPLICAS: "{{ webitel_pg_dsn_replicas }}?sslmode=disable&connect_timeout=10"`) додати у env-defaults ролей:
  - `webitel_engine`, `webitel_call_center`, `webitel_flow_manager`, `webitel_storage`.
- Решта сервісів і їх rw-DSN не змінюються (порт/хост приходять із `webitel_pg_dsn_base`).

## 5. Потік даних

```
webitel_* service ──DATA_SOURCE (rw, :6432)──┐
opensips / grafana ──────────────(rw, :6432)──┤
                                              ▼
engine/cc/flow/storage ─replicas (ro, :6433)─► HAProxy ──httpchk /master|/replica (:8008, TLS опц.)─► Patroni nodes :5432
```
- HAProxy маршрутизує rw тільки на ноду, що повертає 200 на `/master` (лідер); ro — roundrobin по тих, що повертають 200 на `/replica`.
- failover Patroni → health-check перемикає бекенд у межах `inter/fall/rise`.

## 6. Обробка помилок / крайові випадки

- **Колізія портів:** на co-located Patroni-нодах 5432 зайнятий — тому 6432/6433. `haproxy_bind_addr=0.0.0.0` не конфліктує (Patroni слухає 5432; HAProxy — 6432/6433).
- **Немає лідера/реплік:** усі бекенди в DOWN → з'єднання відхиляються (очікувано під час viборів); сервіси ретраять (`connect_timeout`).
- **TLS вимкнено (dev/single):** plain-http чек; бандл не збирається.
- **Не-HA / single / multihost без `haproxy`:** `webitel_pg_haproxy=false`, поведінка ідентична поточній (порт 5432, consul DNS / postgres[0]).
- **Кілька haproxy-хостів у dedicated без VIP:** береться `[0]`; справжній HA — окремий етап (keepalived/VIP).

## 7. Тестування

- `ansible-lint` + `yamllint` + `--syntax-check` (CI, як у фазі 1).
- Рендер `haproxy.cfg.j2` у обох режимах (sidecar/dedicated), з/без TLS — перевірити коректність binds, бекендів, health-check шляхів.
- Перевірка обчислення `webitel_pg_host` / `webitel_pg_port` / `webitel_pg_dsn_replicas` на прикладах інвентарю (sidecar, dedicated, single, multihost).
- Molecule — разом із кластерними ролями (фаза 2), якщо середовище дозволяє co-located Patroni.

## 8. Поза скоупом

- keepalived/VIP для HA dedicated-HAProxy.
- Read-split у сервісах, що не мають `SQL_DATA_SOURCE_REPLICAS`.
- Інтеграція haproxy-метрик у Grafana-дашборди (listener піднімається, дашборд — окремо).
- Керування HAProxy через Nomad (узгоджено з phased-підходом — поки systemd).
