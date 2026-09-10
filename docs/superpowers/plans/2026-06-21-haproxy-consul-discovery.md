# HAProxy → Consul discovery (PG + AMQP) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Перевести HAProxy на Consul service discovery (`resolvers` + `server-template`): PG-бекенди за роль-тегами Patroni (`primary`/`replica`), новий AMQP-лісенер для RabbitMQ; прибрати Patroni-REST httpchk + PKI-залежність HAProxy.

**Architecture:** HAProxy резолвить бекенди напряму з Consul DNS (127.0.0.1:8600) через `server-template`. PG-RW → `primary.<scope>.service.consul`, PG-RO → `replica.<scope>`, AMQP → `rabbitmq.service.consul`. topology отримує `webitel_amqp_haproxy`/`webitel_amqp_port` і перемикає `webitel_amqp_host`/url на локальний haproxy (дзеркало PG). Заодно фіксується латентний баг `master.` → `primary.` у non-haproxy HA-шляху. preflight валідує co-location (споживачі PG/AMQP мають локальний haproxy).

**Tech Stack:** Ansible (ansible-core), Jinja2, HAProxy 3.2 `server-template`/`resolvers`, Consul DNS, yamllint, ansible-lint. Верифікація: рендер шаблону + `haproxy -c`, debug topology-виразів, syntax-check.

**Спека:** [docs/superpowers/specs/2026-06-21-haproxy-consul-discovery-design.md](../specs/2026-06-21-haproxy-consul-discovery-design.md)

---

## Файлова структура

- **Modify:** `roles/haproxy/defaults/main.yml` — додати `haproxy_amqp_port`, `haproxy_consul_dns`, `haproxy_pg_primary_tag`, `haproxy_pg_replica_tag`, `haproxy_rabbitmq_backends`; видалити `haproxy_tls_enabled`, `haproxy_ssl_dir`.
- **Modify:** `roles/haproxy/templates/haproxy.cfg.j2` — `resolvers consul`; PG-listener-и на `server-template` за тегами; новий `rabbitmq-amqp`; прибрати httpchk/TLS-чек.
- **Modify:** `roles/haproxy/tasks/configure.yml` — видалити таск збірки PKI-бандла.
- **Modify:** `roles/topology/tasks/main.yml` — `webitel_amqp_haproxy` (флаг), `webitel_amqp_port` (факт), переписати `webitel_amqp_host`, `webitel_amqp_url` (порт), фікс `master.`→`primary.`.
- **Modify:** `playbooks/preflight.yml` — assert co-location PG/AMQP-споживачів.
- **Modify:** `roles/haproxy/README.md` — оновити під Consul discovery.
- **Не чіпаємо:** `roles/haproxy/tasks/install.yml`, `main.yml`, `roles/patroni/*`, `roles/rabbitmq/*` (вони вже реєструють сервіси в Consul), порти 6432/6433.

---

## Task 1: haproxy defaults

**Files:**
- Modify: `roles/haproxy/defaults/main.yml`

- [ ] **Step 1: Видалити TLS-змінні та додати нові**

Замінити блок (рядки з `# TLS до Patroni REST` до кінця файлу) — прибрати `haproxy_tls_enabled`/`haproxy_ssl_dir`, додати нові. Підсумковий хвіст файлу після `haproxy_backends`:

```yaml
# Бекенди RabbitMQ поточного ДЦ (фолбек — усі rabbitmq). Використовується як
# к-сть слотів server-template і як умова рендеру AMQP-лісенера.
haproxy_rabbitmq_backends: >-
  {{ (groups['rabbitmq'] | default([])
      | map('extract', hostvars)
      | selectattr('datacenter', 'defined')
      | selectattr('datacenter', '==', datacenter)
      | map(attribute='inventory_hostname') | list)
     or (groups['rabbitmq'] | default([])) }}

# AMQP-лісенер. 5673 (не 5672) — co-located rabbitmq тримає 5672, як PG-haproxy
# узяв 6432 проти Patroni:5432.
haproxy_amqp_port: 5673

# Резолвер для server-template — НАПРЯМУ в Consul DNS (не dnsmasq): свіжі
# health-фільтровані відповіді у failover-критичному шляху, без залежності від dnsmasq.
haproxy_consul_dns: "127.0.0.1:8600"

# Теги ролі Patroni у Consul. Patroni 3.x/4.x: primary/replica (master — застарілий
# alias до 3.0). Конфігуровно на випадок старішої версії.
haproxy_pg_primary_tag: primary
haproxy_pg_replica_tag: replica

# Prometheus exporter listener (опційно)
haproxy_metrics_enabled: false
haproxy_metrics_port: 8405
```

⚠️ Переконатися, що рядки `haproxy_tls_enabled:` і `haproxy_ssl_dir:` видалені повністю.

- [ ] **Step 2: yamllint**

Run:
```bash
yamllint roles/haproxy/defaults/main.yml
```
Expected: без помилок.

- [ ] **Step 3: Commit**

```bash
git add roles/haproxy/defaults/main.yml
git commit -m "feat(haproxy): add Consul-discovery vars, drop REST-TLS vars"
```

---

## Task 2: haproxy.cfg.j2 + прибрати PKI-бандл

**Files:**
- Modify: `roles/haproxy/templates/haproxy.cfg.j2`
- Modify: `roles/haproxy/tasks/configure.yml`

- [ ] **Step 1: Повністю замінити вміст `roles/haproxy/templates/haproxy.cfg.j2`**

```jinja
# {{ ansible_managed }}
global
    log /dev/log local0
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    mode tcp
    log global
    option tcplog
    option dontlognull
    option log-health-checks
    retries 3
    timeout queue 5s
    timeout connect 5s
    timeout client 60m
    timeout server 60m
    timeout check 5s

resolvers consul
    nameserver consul {{ haproxy_consul_dns }}
    accepted_payload_size 8192
    hold valid 5s
    resolve_retries 3
{% if haproxy_backends | length > 0 %}

listen postgres-rw
    bind {{ haproxy_bind_addr }}:{{ haproxy_pg_rw_port }}
    server-template pgrw 1 {{ haproxy_pg_primary_tag }}.{{ webitel_patroni_scope }}.service.consul:5432 check resolvers consul resolve-prefer ipv4

listen postgres-ro
    bind {{ haproxy_bind_addr }}:{{ haproxy_pg_ro_port }}
    balance roundrobin
    server-template pgro {{ haproxy_backends | length }} {{ haproxy_pg_replica_tag }}.{{ webitel_patroni_scope }}.service.consul:5432 check resolvers consul resolve-prefer ipv4
{% endif %}
{% if haproxy_rabbitmq_backends | length > 0 %}

listen rabbitmq-amqp
    bind {{ haproxy_bind_addr }}:{{ haproxy_amqp_port }}
    balance leastconn
    server-template rmq {{ haproxy_rabbitmq_backends | length }} rabbitmq.service.consul:5672 check resolvers consul resolve-prefer ipv4
{% endif %}
{% if haproxy_metrics_enabled | bool %}

listen prometheus-metrics
    bind 127.0.0.1:{{ haproxy_metrics_port }}
    mode http
    http-request use-service prometheus-exporter if { path /metrics }
    no log
{% endif %}
```

- [ ] **Step 2: Видалити PKI-бандл-таск із `roles/haproxy/tasks/configure.yml`**

Видалити повністю перший таск «Assemble HAProxy client cert bundle for Patroni REST TLS checks» (разом із його коментарем-блоком, рядки 2-15). Файл має починатися одразу з таска «Render haproxy.cfg».

- [ ] **Step 3: Рендер шаблону на мок-даних + перевірка `haproxy -c` (якщо haproxy є локально)**

Створити throwaway `_hap_render.yml` у корені:

```yaml
---
- hosts: localhost
  gather_facts: false
  vars:
    haproxy_bind_addr: "0.0.0.0"
    haproxy_pg_rw_port: 6432
    haproxy_pg_ro_port: 6433
    haproxy_amqp_port: 5673
    haproxy_consul_dns: "127.0.0.1:8600"
    haproxy_pg_primary_tag: primary
    haproxy_pg_replica_tag: replica
    haproxy_metrics_enabled: false
    webitel_patroni_scope: webitel
    haproxy_backends: [pg1, pg2, pg3]
    haproxy_rabbitmq_backends: [mq1, mq2, mq3]
  tasks:
    - name: Render
      ansible.builtin.template:
        src: roles/haproxy/templates/haproxy.cfg.j2
        dest: /tmp/haproxy.cfg.rendered
```

Run:
```bash
ansible-playbook _hap_render.yml >/dev/null 2>&1 && cat /tmp/haproxy.cfg.rendered
```
Expected (ключове): є `resolvers consul` із `nameserver consul 127.0.0.1:8600`; `postgres-rw` зі `server-template pgrw 1 primary.webitel.service.consul:5432 check resolvers consul resolve-prefer ipv4`; `postgres-ro` зі `server-template pgro 3 replica.webitel.service.consul:5432 …`; `rabbitmq-amqp` на `:5673` зі `server-template rmq 3 rabbitmq.service.consul:5672 …`. Жодного `httpchk`/`check-ssl`/`8008`.

- [ ] **Step 4: Прибрати throwaway та прогнати лінтери**

Run:
```bash
rm _hap_render.yml
yamllint roles/haproxy/tasks/configure.yml
ansible-lint roles/haproxy/
```
Expected: yamllint без помилок; ansible-lint роль `haproxy` — profile production passed (шаблон .j2 ansible-lint перевіряє на jinja-синтаксис).

- [ ] **Step 5: Commit**

```bash
git add roles/haproxy/templates/haproxy.cfg.j2 roles/haproxy/tasks/configure.yml
git commit -m "feat(haproxy): Consul-discovery backends for PG and AMQP"
```

---

## Task 3: topology — AMQP факти + фікс primary-тегу

**Files:**
- Modify: `roles/topology/tasks/main.yml`

- [ ] **Step 1: Додати `webitel_amqp_haproxy` у «Resolve topology flags»**

У таску «Resolve topology flags» (set_fact, поряд із `webitel_pg_haproxy`) додати рядок:

```yaml
    webitel_amqp_haproxy: "{{ (groups['haproxy'] | default([]) | length > 0) and (groups['rabbitmq'] | default([]) | length > 0) }}"
```

- [ ] **Step 2: Фікс `master.` → `primary.` у `webitel_pg_host`**

У таску «Resolve dependency hosts and ports», у виразі `webitel_pg_host`, замінити:

```yaml
                           else (('master.' + webitel_patroni_scope + '.service.consul') if ha_mode
```

на:

```yaml
                           else (('primary.' + webitel_patroni_scope + '.service.consul') if ha_mode
```

(Patroni 3.x/4.x реєструє тег `primary`; `master` — застарілий alias.)

- [ ] **Step 3: Переписати `webitel_amqp_host` і додати `webitel_amqp_port`**

У тому ж таску «Resolve dependency hosts and ports» замінити блок `webitel_amqp_host`:

```yaml
    webitel_amqp_host: >-
      {{ external_amqp_host if external_amqp_host is defined
         else ('rabbitmq.service.consul' if ha_mode
               else ('127.0.0.1' if single_node
                     else hostvars[groups['rabbitmq'][0]].ansible_default_ipv4.address)) }}
```

на (дзеркало логіки `webitel_pg_host` для haproxy-гілки):

```yaml
    webitel_amqp_host: >-
      {{ external_amqp_host if external_amqp_host is defined
         else ('127.0.0.1' if (webitel_amqp_haproxy and inventory_hostname in (groups['haproxy'] | default([])))
               else (hostvars[(_topology_haproxy_dc_hosts or groups['haproxy'])[0]].ansible_default_ipv4.address
                     if webitel_amqp_haproxy
                     else ('rabbitmq.service.consul' if ha_mode
                           else ('127.0.0.1' if single_node
                                 else hostvars[groups['rabbitmq'][0]].ansible_default_ipv4.address)))) }}
    webitel_amqp_port: >-
      {{ external_amqp_port if external_amqp_port is defined
         else (haproxy_amqp_port if webitel_amqp_haproxy else 5672) }}
```

- [ ] **Step 4: Додати порт у `webitel_amqp_url`**

У таску «Build connection strings» замінити вираз `webitel_amqp_url`:

```yaml
    webitel_amqp_url: >-
      {{ external_amqp_url if external_amqp_url is defined
         else 'amqp://' + webitel_amqp_user + ':' + webitel_amqp_password
              + '@' + webitel_amqp_host + ':5672' }}
```

на:

```yaml
    webitel_amqp_url: >-
      {{ external_amqp_url if external_amqp_url is defined
         else 'amqp://' + webitel_amqp_user + ':' + webitel_amqp_password
              + '@' + webitel_amqp_host + ':' + (webitel_amqp_port | string) }}
```

- [ ] **Step 5: Перевірити вирази на localhost (без груп haproxy/rabbitmq → non-haproxy гілка)**

Run:
```bash
ansible localhost -m debug -a "msg={{ (haproxy_amqp_port if webitel_amqp_haproxy else 5672) }}" \
  -e webitel_amqp_haproxy=false -e haproxy_amqp_port=5673
ansible localhost -m debug -a "msg={{ (haproxy_amqp_port if webitel_amqp_haproxy else 5672) }}" \
  -e webitel_amqp_haproxy=true -e haproxy_amqp_port=5673
```
Expected: перший → `5672`, другий → `5673`.

- [ ] **Step 6: Перевірити, що фікс тегу застосувався**

Run:
```bash
grep -n "primary\.' + webitel_patroni_scope\|master\.' + webitel_patroni_scope" roles/topology/tasks/main.yml
```
Expected: рядок із `primary.' + webitel_patroni_scope`; жодного `master.' + webitel_patroni_scope`.

- [ ] **Step 7: yamllint + syntax-check**

Run:
```bash
yamllint roles/topology/tasks/main.yml
for inv in singlehost multihost failover warm-standby-2dc; do
  ansible-playbook --syntax-check -i "inventories/${inv}.example" site.yml >/dev/null 2>&1 && echo "$inv OK" || echo "$inv FAIL"
done
```
Expected: yamllint без помилок; усі чотири syntax-check OK.

- [ ] **Step 8: Commit**

```bash
git add roles/topology/tasks/main.yml
git commit -m "feat(topology): AMQP-via-haproxy facts; fix Patroni primary tag"
```

---

## Task 4: preflight co-location + README

**Files:**
- Modify: `playbooks/preflight.yml`
- Modify: `roles/haproxy/README.md`

- [ ] **Step 1: Додати assert co-location у `playbooks/preflight.yml`**

У плей «Preflight checks» (hosts: all, tasks:) додати таск (зручно — наприкінці списку tasks):

```yaml
    - name: Preflight | PG/AMQP consumers must have local HAProxy (sidecar)
      ansible.builtin.assert:
        that:
          - (_pg_amqp_consumers | difference(groups['haproxy'] | default([]))) | length == 0
        fail_msg: >-
          HAProxy sidecar активний, але ці хости споживають PG/AMQP без локального
          haproxy: {{ _pg_amqp_consumers | difference(groups['haproxy'] | default([])) | join(', ') }}.
          Додайте 'haproxy' у services цих хостів.
        quiet: true
      vars:
        _pg_amqp_consumers: >-
          {{ ((groups['webitel_core'] | default([]))
              + (groups['webitel_engine'] | default([]))
              + (groups['webitel_call_center'] | default([]))
              + (groups['webitel_flow_manager'] | default([]))
              + (groups['webitel_storage'] | default([]))
              + (groups['webitel_messages'] | default([]))
              + (groups['webitel_logger'] | default([]))
              + (groups['webitel_cases'] | default([]))
              + (groups['webitel_media_exporter'] | default([]))) | unique }}
      when:
        - (groups['haproxy'] | default([])) | length > 0
      run_once: true
```

- [ ] **Step 2: Замінити вміст `roles/haproxy/README.md`**

```markdown
# haproxy

HAProxy перед Patroni-кластером PostgreSQL та RabbitMQ-кластером. Бекенди беруться
з **Consul service discovery** (`resolvers` + `server-template`), напряму з Consul DNS
(`127.0.0.1:8600`, не через dnsmasq).

TCP-listener-и:
- `postgres-rw` (`:6432`) → лідер (`primary.<scope>.service.consul`)
- `postgres-ro` (`:6433`) → репліки, roundrobin (`replica.<scope>.service.consul`)
- `rabbitmq-amqp` (`:5673`) → rabbitmq-ноди, leastconn (`rabbitmq.service.consul`)

Роль ноди PG визначає Patroni через Consul-теги (`primary`/`replica`), rabbitmq —
через Consul peer-discovery (TTL-heartbeat). HAProxy додає LB + стабільний локальний
сокет + свій TCP-чек; членство бекендів синхронне з вердиктом Consul.

PG-listener-и рендеряться за наявності `haproxy_backends`, AMQP — за наявності
`haproxy_rabbitmq_backends`.

## Топологія
- **sidecar** — `haproxy` у `services` кожного app-хоста; сервіси ходять на `127.0.0.1`.
- **dedicated** — `haproxy` на одному хості; сервіси ходять на його IP.

`webitel_pg_*` / `webitel_amqp_*` обчислюються в topology залежно від наявності групи
`haproxy`. preflight вимагає, щоб PG/AMQP-споживачі мали локальний haproxy.

## Ключові змінні
`haproxy_pg_rw_port` (6432), `haproxy_pg_ro_port` (6433), `haproxy_amqp_port` (5673),
`haproxy_bind_addr` (0.0.0.0), `haproxy_consul_dns` (127.0.0.1:8600),
`haproxy_pg_primary_tag` (primary), `haproxy_pg_replica_tag` (replica),
`haproxy_backends` (Patroni-ноди ДЦ), `haproxy_rabbitmq_backends` (rabbitmq-ноди ДЦ),
`haproxy_metrics_enabled` (8405).

## Залежності
Consul-агент із DNS на `:8600`; зареєстровані в Consul Patroni- та RabbitMQ-сервіси.
```

- [ ] **Step 3: yamllint + ansible-lint (мої файли)**

Run:
```bash
yamllint playbooks/preflight.yml
ansible-lint playbooks/preflight.yml 2>&1 | grep -E ':[0-9]+' | grep -v 'roles/topology/' || echo ">>> жодного violation поза pre-existing topology <<<"
```
Expected: yamllint без помилок; жодного ansible-lint violation у `preflight.yml` (топологічні var-naming — pre-existing, не наші).

- [ ] **Step 4: Commit**

```bash
git add playbooks/preflight.yml roles/haproxy/README.md
git commit -m "feat(preflight): require local haproxy for PG/AMQP consumers; docs"
```

---

## Фінальна верифікація (вся фіча разом)

- [ ] **Лінт + syntax-check (як у CI; топологічні var-naming — pre-existing)**

Run:
```bash
yamllint .
ansible-lint roles/haproxy/
for inv in singlehost multihost failover warm-standby-2dc; do
  ansible-playbook --syntax-check -i "inventories/${inv}.example" site.yml >/dev/null 2>&1 && echo "$inv OK" || echo "$inv FAIL"
done
```
Expected: `yamllint .` без помилок; роль `haproxy` profile production passed; усі syntax-check OK.

- [ ] **(На реальному кластері) підтвердити Consul-тег і резолв бекендів**

Run на haproxy-ноді:
```bash
dig @127.0.0.1 -p 8600 primary.{{ scope }}.service.consul +short   # IP лідера
dig @127.0.0.1 -p 8600 replica.{{ scope }}.service.consul +short   # IP реплік
dig @127.0.0.1 -p 8600 rabbitmq.service.consul +short              # IP rabbitmq-нод
echo 'show servers state' | socat stdio /run/haproxy/admin.sock     # бекенди UP
```
Expected: DNS повертає очікувані IP; `postgres-rw`/`postgres-ro`/`rabbitmq-amqp` мають UP-сервери.
```
