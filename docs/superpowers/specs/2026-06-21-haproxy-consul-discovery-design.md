# HAProxy → Consul discovery для PG та AMQP (Блок 3.3)

**Дата:** 2026-06-21
**Статус:** дизайн узгоджено, план не написано

## Проблема / мотивація

1. **AMQP без балансування й активних чеків.** Сервіси `webitel_*` у `ha_mode`
   ходять у RabbitMQ через `rabbitmq.service.consul` (DNS round-robin). Failover
   працює лише якщо клієнт перерезолвлює DNS на переконекті; немає активного LB і
   стабільного локального endpoint. Хочемо балансування + швидке довиявлення.

2. **PG-HAProxy через Patroni REST httpchk.** Поточний HAProxy визначає роль ноди
   запитом `httpchk GET /master` проти Patroni REST по HTTPS:8008, через що в ролі
   тягнеться TLS-машинерія (`haproxy_tls_enabled`, `check-ssl crt … ca-file …`,
   таск збірки PKI peer-бандла). Patroni вже реєструє роль у Consul тегами — REST-чек
   надлишковий.

Обидва вирішуються одним механізмом: **HAProxy бере бекенди з Consul DNS**
(`resolvers` + `server-template`), а Consul-вердикт про здоровʼя зберігається.

### Чому Consul-вердикт «розумний»

- **Patroni**: `register_service: true` → кожна нода реєструє сервіс `<scope>` з
  авто-тегами ролі + `service_tags: [<scope>]`. Канонічні теги ролі на Patroni 3.x/4.x
  (наш apt-пакет): **`primary` / `replica` / `standby-leader`** (`master` — застарілий
  alias до Patroni 3.0). Consul DNS за тегом віддає потрібну роль:
  `primary.<scope>.service.consul`, `replica.<scope>.service.consul`.
- **RabbitMQ**: `cluster_formation.peer_discovery_backend = consul`,
  `svc_addr_auto = true` → кожна нода сама реєструється як сервіс `rabbitmq` і веде
  TTL-heartbeat. Вердикт «процес rabbit живий і говорить з Consul» — глибший за голий
  TCP-connect на 5672.

## Механізм

Спільна секція `resolvers` — напряму в Consul DNS, **не через dnsmasq**:

```haproxy
resolvers consul
    nameserver consul {{ haproxy_consul_dns }}   # дефолт 127.0.0.1:8600 (локальний агент)
    accepted_payload_size 8192
    hold valid 5s
    resolve_retries 3
```

**Чому не dnsmasq:** HAProxy робить failover-критичний резолв і потребує найсвіжіших
health-фільтрованих відповідей. Consul DNS віддає TTL 0 саме для цього; dnsmasq — кеш
(з можливим `min-cache-ttl`), який може віддати стале `primary.<scope>` → повільний
перехід при перевиборах. Свіжістю вже керує сам HAProxy (`hold valid` + retries), тож
dnsmasq-кеш зверху зайвий. Прямий Consul також дає коректні SRV/EDNS (TCP-fallback).
dnsmasq лишається загальним резолвером хоста (`.consul` для сервісів/nginx).
`haproxy_consul_dns` конфігуровний — за потреби перемикається на `127.0.0.1:53`.

HAProxy `server-template` періодично перерезолвлює DNS-імʼя й тримає бекенд-сет
синхронним із Consul (only-passing за замовчуванням), плюс власний `check`.

### PostgreSQL (теги ролі)

```haproxy
listen postgres-rw
    bind {{ haproxy_bind_addr }}:{{ haproxy_pg_rw_port }}
    server-template pgrw 1 {{ haproxy_pg_primary_tag }}.{{ webitel_patroni_scope }}.service.consul:5432 check resolvers consul resolve-prefer ipv4

listen postgres-ro
    bind {{ haproxy_bind_addr }}:{{ haproxy_pg_ro_port }}
    balance roundrobin
    server-template pgro {{ haproxy_backends | length }} {{ haproxy_pg_replica_tag }}.{{ webitel_patroni_scope }}.service.consul:5432 check resolvers consul resolve-prefer ipv4
```

Теги ролі конфігуровні: `haproxy_pg_primary_tag: primary`, `haproxy_pg_replica_tag: replica`
(дефолти під Patroni 3.x/4.x; при потребі легко перевести на `master` для старих версій).
`mode tcp` успадковується з `defaults`. Прибираємо `option httpchk`, `http-check`,
`check port 8008`, `check-ssl/crt/ca-file`.

### RabbitMQ (новий лісенер)

```haproxy
listen rabbitmq-amqp
    bind {{ haproxy_bind_addr }}:{{ haproxy_amqp_port }}   # 5673; 5672 зайнятий co-located rabbitmq
    balance leastconn
    server-template rmq {{ haproxy_rabbitmq_backends | length }} rabbitmq.service.consul:5672 check resolvers consul resolve-prefer ipv4
```

Рендериться лише якщо `haproxy_rabbitmq_backends | length > 0`. PG-лісенери —
лише якщо `haproxy_backends | length > 0`.

## Семантика фейловера PG

Під час перевиборів тег `master` на мить зникає → `master.<scope>` віддає порожньо →
RW-конекти падають швидко (а не йдуть на демоутнуту ноду); новий лідер зʼявляється →
`server-template` перерезолвлює (`hold valid 5s`) → RW відновлюється. Коректніше за
роутинг у транзиті.

## Зміни в ролі haproxy

- **defaults:** додати `haproxy_amqp_port: 5673`, `haproxy_consul_dns: "127.0.0.1:8600"`,
  `haproxy_pg_primary_tag: primary`, `haproxy_pg_replica_tag: replica`,
  `haproxy_rabbitmq_backends` (DC-aware, як `haproxy_backends`). **Видалити**
  `haproxy_tls_enabled`, `haproxy_ssl_dir`.
- **templates/haproxy.cfg.j2:** додати `resolvers consul`; переписати postgres-rw/ro
  на `server-template` за тегами; додати `rabbitmq-amqp`; прибрати httpchk/TLS-чек.
- **tasks/configure.yml:** видалити таск `Assemble HAProxy client cert bundle …`
  (PKI-бандл більше не потрібен).
- **tasks/install.yml, main.yml:** без змін.

## Зміни в topology (roles/topology/tasks/main.yml)

- Новий прапор `webitel_amqp_haproxy` (аналог `webitel_pg_haproxy`): true коли
  група `haproxy` непорожня І є rabbitmq-ноди.
- Новий факт `webitel_amqp_port`: `external_amqp_port` → інакше
  `haproxy_amqp_port if webitel_amqp_haproxy else 5672`.
- `webitel_amqp_host`: коли `webitel_amqp_haproxy` → `127.0.0.1` якщо хост у групі
  `haproxy`, інакше IP haproxy-ноди DC (як зроблено для PG); інакше поточна логіка
  (`rabbitmq.service.consul` / single / перша нода групи).
- AMQP-URL: `:5672` → `:{{ webitel_amqp_port }}`.

**Фікс латентного бага:** рядок 123 використовує `'master.' + scope + '.service.consul'`
для non-haproxy HA-шляху. На Patroni 3.x/4.x тег — `primary`, тож `master.` не
резолвиться (хіба через legacy-alias). Замінити на `primary.` (узгоджено з
`haproxy_pg_primary_tag`). Це окремий, але повʼязаний фікс — без нього `ha_mode` без
групи `haproxy` дає зламаний `webitel_pg_host`.

`webitel_pg_haproxy`-логіка (порти 6432/6433) лишається — ми змінюємо лише ЯК HAProxy
знаходить бекенди + правимо тег у DNS-імені.

**Перед мерджем — підтвердити тег на живому кластері:**
`dig @127.0.0.1 -p 8600 primary.<scope>.service.consul +short` має повернути IP лідера
(і `master.<scope>` — порожньо, якщо alias уже прибрано).

## Preflight: валідація co-location

Коли `groups['haproxy']` непорожня (sidecar-режим активний), кожен хост, що споживає
PG/AMQP, мусить мати локальний haproxy. Споживачі = хости у будь-якій із груп:
`webitel_core, webitel_engine, webitel_call_center, webitel_flow_manager,
webitel_storage, webitel_messages, webitel_logger, webitel_cases,
webitel_media_exporter`.

Assert (на `hosts: all`, після topology): для кожного такого хоста
`inventory_hostname in groups['haproxy']`. fail_msg перелічує хости-порушники.

## Багатоцентровий випадок (2DC) — поза скоупом цієї зміни

`standby-leader.<scope>.service.consul` доступний тим самим механізмом, але роутинг
запису між ДЦ регулюється окремим phase-3 warm-standby планом
([docs/superpowers/plans/2026-06-17-patroni-warm-standby-2dc.md], не передизайнюється
тут). Ця зміна покриває within-DC discovery (master/replica у межах свого ДЦ через
локальний Consul DNS).

## Поза скоупом

- Aliveness-API health-check для rabbitmq (обрали TCP-connect для старту).
- Зміна портів PG (6432/6433) — лишаються.
- TLS-термінація postgres/amqp на HAProxy — HAProxy лишається TCP-passthrough.
