# HAProxy для балансування Patroni (PostgreSQL) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Поставити HAProxy перед Patroni-кластером із двома портами (rw `6432` / ro `6433`) і перевести строку підключення сервісів на HAProxy, з конфігурованою топологією sidecar/dedicated через `services`-модель.

**Architecture:** Нова тонка роль `haproxy` (install/configure/template/handlers) деплоїться на хости групи `haproxy`. `webitel_pg_host` стає host-aware (localhost у sidecar, IP haproxy-ноди у dedicated, поточний fallback інакше). Health-check бекендів — через Patroni REST `/master` (rw) і `/replica` (ro) на `:8008`, опційно по TLS. Реплік-DSN вмикається лише в сервісах, що його підтримують.

**Tech Stack:** Ansible (FQCN, `deb822_repository`, `lineinfile`, `template`), HAProxy (mode tcp), Patroni REST health-checks, наявна `pki`-роль (peer-серти).

**Спец:** [docs/superpowers/specs/2026-06-12-haproxy-patroni-lb-design.md](../specs/2026-06-12-haproxy-patroni-lb-design.md)

> **⚠️ Project rule — NO COMMITS без явного дозволу користувача** (memory `feedback_no_commits`).
> Кожна задача закінчується кроком **Stage** (`git add`), а не `git commit`. Реальний коміт — лише на фінальному чекпойнті, коли користувач дасть «ок».
>
> **Тестове середовище:** кроки, позначені `[VM]`, виконуються на реальній Debian-VM (рендер шаблонів/факти потребують live-хоста). Локально (без хостів) доступні лише lint + `--syntax-check`.

---

## Файлова структура

**Створюємо:**
- `roles/haproxy/defaults/main.yml` — змінні ролі (порти, бекенди, TLS, метрики)
- `roles/haproxy/tasks/main.yml` — include install + configure
- `roles/haproxy/tasks/install.yml` — keyring + репо + пакет
- `roles/haproxy/tasks/configure.yml` — TLS-бандл + шаблон + enable
- `roles/haproxy/templates/haproxy.cfg.j2` — конфіг HAProxy
- `roles/haproxy/handlers/main.yml` — reload haproxy
- `roles/haproxy/README.md` — опис ролі

**Модифікуємо:**
- `playbooks/vars/known_services.yml` — додати `haproxy` у валідний список
- `inventories/failover.example/00-service-groups.yml` — оголосити групу `haproxy`
- `inventories/failover.example/01-hosts.yml` — додати `haproxy` у `services` (демо sidecar)
- `playbooks/database.yml` — play для групи `haproxy`
- `inventories/{failover.example,production,multihost.example,singlehost.example,warm-standby-2dc.example}/group_vars/all/main.yml` — host-aware `webitel_pg_host`, `webitel_pg_port`, `webitel_pg_dsn_replicas`, порти
- `roles/opensips/tasks/configure.yml` — порт у regex
- `roles/grafana/tasks/configure.yml` — порт у datasource URL
- `roles/webitel_engine/defaults/main.yml` — `SQL_DATA_SOURCE_REPLICAS`
- `roles/webitel_call_center/defaults/main.yml` — `SQL_DATA_SOURCE_REPLICAS`
- `roles/webitel_flow_manager/defaults/main.yml` — `SQL_DATA_SOURCE_REPLICAS`
- `roles/webitel_storage/defaults/main.yml` — `SQL_DATA_SOURCE_REPLICAS`

---

## Task 1: Зареєструвати service-групу `haproxy`

**Files:**
- Modify: `playbooks/vars/known_services.yml`
- Modify: `inventories/failover.example/00-service-groups.yml`

- [ ] **Step 1: Додати `haproxy` у список відомих сервісів**

У `playbooks/vars/known_services.yml`, у список `webitel_known_services`, після рядка `  - grafana` додати:

```yaml
  - haproxy
```

- [ ] **Step 2: Оголосити порожню групу в інвентарі**

У `inventories/failover.example/00-service-groups.yml`, у блок `all.children`, після рядка `    grafana: {}` (або поряд із `patroni: {}`) додати:

```yaml
    haproxy: {}
```

- [ ] **Step 3: yamllint**

Run: `yamllint playbooks/vars/known_services.yml inventories/failover.example/00-service-groups.yml`
Expected: no errors (exit 0)

- [ ] **Step 4: Stage**

```bash
git add playbooks/vars/known_services.yml inventories/failover.example/00-service-groups.yml
```

---

## Task 2: `haproxy` роль — defaults

**Files:**
- Create: `roles/haproxy/defaults/main.yml`

- [ ] **Step 1: Написати defaults**

Створити `roles/haproxy/defaults/main.yml`:

```yaml
---
# APT
haproxy_keyring: /usr/share/keyrings/haproxy.gpg
haproxy_apt_branch: "3.2"

# Порти балансувальника (єдина схема для sidecar і dedicated; 6432/6433 щоб не
# конфліктувати з co-located Patroni на 5432). Канонічні значення дублюються в
# group_vars/all для обчислення DSN — тримати синхронно.
haproxy_pg_rw_port: 6432
haproxy_pg_ro_port: 6433

# 0.0.0.0 коректно і для sidecar (доступ по 127.0.0.1), і для dedicated (доступ
# по IP ноди іншими хостами). Колізії з Patroni:5432 немає — порти інші.
haproxy_bind_addr: "0.0.0.0"

# Бекенди = Patroni-ноди поточного ДЦ (фолбек — усі patroni, якщо datacenter не заданий)
haproxy_backends: >-
  {{ (groups['patroni'] | default([])
      | map('extract', hostvars)
      | selectattr('datacenter', 'defined')
      | selectattr('datacenter', '==', datacenter | default('dc1'))
      | map(attribute='inventory_hostname') | list)
     or (groups['patroni'] | default([])) }}

# TLS до Patroni REST (health-checks). Вмикається разом із PKI.
haproxy_tls_enabled: "{{ patroni_tls_enabled | default(consul_pki_enabled | default(false)) }}"
haproxy_ssl_dir: "{{ pki_remote_dir | default('/etc/ssl/app') }}"

# Prometheus exporter listener (опційно)
haproxy_metrics_enabled: false
haproxy_metrics_port: 8405
```

- [ ] **Step 2: yamllint**

Run: `yamllint roles/haproxy/defaults/main.yml`
Expected: no errors

- [ ] **Step 3: Stage**

```bash
git add roles/haproxy/defaults/main.yml
```

---

## Task 3: `haproxy` роль — install.yml

**Files:**
- Create: `roles/haproxy/tasks/install.yml`

- [ ] **Step 1: Написати install.yml**

Створити `roles/haproxy/tasks/install.yml` (патерн keyring+repo як у `roles/patroni/tasks/install.yml`):

```yaml
---
- name: Download HAProxy archive keyring
  ansible.builtin.get_url:
    url: https://haproxy.debian.net/haproxy-archive-keyring.gpg
    dest: "{{ haproxy_keyring }}"
    mode: "0644"

- name: Add HAProxy repository
  ansible.builtin.deb822_repository:
    name: haproxy
    types: [deb]
    uris: "http://haproxy.debian.net"
    suites: "{{ ansible_facts.distribution_release }}-backports-{{ haproxy_apt_branch }}"
    components: main
    signed_by: "{{ haproxy_keyring }}"
    state: present
    enabled: true

- name: Install haproxy
  ansible.builtin.apt:
    name: haproxy
    state: present
    install_recommends: false
    update_cache: true
```

- [ ] **Step 2: yamllint**

Run: `yamllint roles/haproxy/tasks/install.yml`
Expected: no errors

- [ ] **Step 3: Stage**

```bash
git add roles/haproxy/tasks/install.yml
```

---

## Task 4: `haproxy` роль — шаблон конфігу

**Files:**
- Create: `roles/haproxy/templates/haproxy.cfg.j2`

- [ ] **Step 1: Написати шаблон**

Створити `roles/haproxy/templates/haproxy.cfg.j2`:

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

listen postgres-rw
    bind {{ haproxy_bind_addr }}:{{ haproxy_pg_rw_port }}
    option httpchk GET /master
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions{% if haproxy_tls_enabled | bool %} check-ssl crt {{ haproxy_ssl_dir }}/peer-{{ inventory_hostname }}-bundle.pem ca-file {{ haproxy_ssl_dir }}/ca.pem{% endif %}

{% for h in haproxy_backends %}
    server {{ h }} {{ hostvars[h].ansible_default_ipv4.address }}:5432 check port 8008 weight {{ hostvars[h].patroni_priority | default(1) }}
{% endfor %}

listen postgres-ro
    bind {{ haproxy_bind_addr }}:{{ haproxy_pg_ro_port }}
    option httpchk GET /replica
    http-check expect status 200
    balance roundrobin
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions{% if haproxy_tls_enabled | bool %} check-ssl crt {{ haproxy_ssl_dir }}/peer-{{ inventory_hostname }}-bundle.pem ca-file {{ haproxy_ssl_dir }}/ca.pem{% endif %}

{% for h in haproxy_backends %}
    server {{ h }} {{ hostvars[h].ansible_default_ipv4.address }}:5432 check port 8008 weight {{ hostvars[h].patroni_priority | default(1) }}
{% endfor %}
{% if haproxy_metrics_enabled | bool %}

listen prometheus-metrics
    bind 127.0.0.1:{{ haproxy_metrics_port }}
    mode http
    http-request use-service prometheus-exporter if { path /metrics }
    no log
{% endif %}
```

- [ ] **Step 2: Stage**

```bash
git add roles/haproxy/templates/haproxy.cfg.j2
```

---

## Task 5: `haproxy` роль — handlers, configure, main

**Files:**
- Create: `roles/haproxy/handlers/main.yml`
- Create: `roles/haproxy/tasks/configure.yml`
- Create: `roles/haproxy/tasks/main.yml`

- [ ] **Step 1: handlers/main.yml**

Створити `roles/haproxy/handlers/main.yml` (патерн як `roles/patroni/handlers/main.yml`):

```yaml
---
- name: Reload haproxy
  ansible.builtin.systemd_service:
    name: haproxy
    state: reloaded
  listen: reload haproxy
```

- [ ] **Step 2: configure.yml**

Створити `roles/haproxy/tasks/configure.yml`. Бандл (peer-cert + key) потрібен HAProxy для клієнтської TLS-автентифікації health-check'ів до Patroni REST; `peer-<host>.pem`/`-key.pem` уже лежать у `{{ haproxy_ssl_dir }}` (їх кладе `pki`-роль на кожен хост у HA):

```yaml
---
- name: Assemble HAProxy client cert bundle for Patroni REST TLS checks
  ansible.builtin.shell:
    cmd: >-
      cat {{ haproxy_ssl_dir }}/peer-{{ inventory_hostname }}.pem
          {{ haproxy_ssl_dir }}/peer-{{ inventory_hostname }}-key.pem
          > {{ haproxy_ssl_dir }}/peer-{{ inventory_hostname }}-bundle.pem
  args:
    creates: "{{ haproxy_ssl_dir }}/peer-{{ inventory_hostname }}-bundle.pem"
  when: haproxy_tls_enabled | bool
  notify: reload haproxy

- name: Set bundle permissions
  ansible.builtin.file:
    path: "{{ haproxy_ssl_dir }}/peer-{{ inventory_hostname }}-bundle.pem"
    mode: "0640"
  when: haproxy_tls_enabled | bool

- name: Render haproxy.cfg
  ansible.builtin.template:
    src: haproxy.cfg.j2
    dest: /etc/haproxy/haproxy.cfg
    owner: root
    group: root
    mode: "0644"
    validate: haproxy -c -f %s
  notify: reload haproxy

- name: Enable and start haproxy
  ansible.builtin.systemd_service:
    name: haproxy
    enabled: true
    state: started
    daemon_reload: true
```

> Примітка: після ротації сертів видалити `peer-<host>-bundle.pem`, щоб `creates` не пропустив перезбірку (поза скоупом — окремий хук ротації).

- [ ] **Step 3: main.yml**

Створити `roles/haproxy/tasks/main.yml` (патерн як `roles/patroni/tasks/main.yml`):

```yaml
---
- name: Install HAProxy
  ansible.builtin.include_tasks:
    file: install.yml
    apply:
      tags: [haproxy_install]
  tags: [haproxy_install]

- name: Configure HAProxy
  ansible.builtin.include_tasks:
    file: configure.yml
    apply:
      tags: [haproxy_configure]
  tags: [haproxy_configure]
```

- [ ] **Step 4: yamllint**

Run: `yamllint roles/haproxy/`
Expected: no errors

- [ ] **Step 5: Stage**

```bash
git add roles/haproxy/handlers/main.yml roles/haproxy/tasks/configure.yml roles/haproxy/tasks/main.yml
```

---

## Task 6: README ролі

**Files:**
- Create: `roles/haproxy/README.md`

- [ ] **Step 1: Написати README** (формат як у наявних роль-README, напр. `roles/patroni/README.md`)

```markdown
# haproxy

HAProxy перед Patroni-кластером PostgreSQL. Два TCP-listener:
- `postgres-rw` (`:6432`) → поточний лідер (`option httpchk GET /master`)
- `postgres-ro` (`:6433`) → репліки, roundrobin (`GET /replica`)

Health-check бекендів — Patroni REST на `:8008` (по TLS, коли `haproxy_tls_enabled`).

## Топологія
- **sidecar** — `haproxy` у `services` кожного app-хоста; сервіси ходять на `127.0.0.1`.
- **dedicated** — `haproxy` на одному хості; сервіси ходять на його IP.

`webitel_pg_host`/`webitel_pg_port`/`webitel_pg_dsn_replicas` обчислюються в
`group_vars/all` залежно від наявності групи `haproxy`.

## Ключові змінні
`haproxy_pg_rw_port` (6432), `haproxy_pg_ro_port` (6433), `haproxy_bind_addr`
(0.0.0.0), `haproxy_backends` (Patroni-ноди ДЦ), `haproxy_tls_enabled`,
`haproxy_metrics_enabled` (8405).

## Залежності
`pki` (peer-серти для TLS health-checks), запущений Patroni-кластер.
```

- [ ] **Step 2: Stage**

```bash
git add roles/haproxy/README.md
```

---

## Task 7: Wire play у database.yml

**Files:**
- Modify: `playbooks/database.yml`

- [ ] **Step 1: Додати play після Patroni**

У кінець `playbooks/database.yml` (після play `Patroni cluster (HA)`) додати:

```yaml

- name: HAProxy load balancer for PostgreSQL
  hosts: haproxy
  become: true
  any_errors_fatal: true
  roles: [haproxy]
```

- [ ] **Step 2: syntax-check**

Run: `ansible-playbook -i inventories/failover.example playbooks/database.yml --syntax-check`
Expected: `playbook: playbooks/database.yml` (exit 0, без помилок парсингу)

- [ ] **Step 3: Stage**

```bash
git add playbooks/database.yml
```

---

## Task 8: Host-aware PG endpoint у group_vars/all

**Files:**
- Modify: `inventories/failover.example/group_vars/all/main.yml`
- Modify: `inventories/production/group_vars/all/main.yml`
- Modify: `inventories/multihost.example/group_vars/all/main.yml`
- Modify: `inventories/singlehost.example/group_vars/all/main.yml`
- Modify: `inventories/warm-standby-2dc.example/group_vars/all/main.yml`

Поточний блок (ідентичний у всіх 5 файлах) виглядає так:

```yaml
webitel_pg_host: >-
  {{ ('master.' + webitel_patroni_scope + '.service.consul') if ha_mode
     else ('127.0.0.1' if single_node else hostvars[groups['postgres'][0]].ansible_default_ipv4.address) }}
```
і нижче:
```yaml
webitel_pg_dsn_base: "postgres://opensips:webitel@{{ webitel_pg_host }}:5432/webitel"
```

- [ ] **Step 1: Замінити `webitel_pg_host` (failover, production, multihost, singlehost)**

У `inventories/failover.example`, `inventories/production`, `inventories/multihost.example`, `inventories/singlehost.example` — замінити блок `webitel_pg_host: >- … }}` на:

```yaml
# Порти HAProxy (синхронізувати з roles/haproxy/defaults/main.yml)
haproxy_pg_rw_port: 6432
haproxy_pg_ro_port: 6433
webitel_pg_haproxy: "{{ (groups['haproxy'] | default([])) | length > 0 }}"
webitel_pg_host: >-
  {{ '127.0.0.1' if inventory_hostname in (groups['haproxy'] | default([]))
     else (hostvars[groups['haproxy'][0]].ansible_default_ipv4.address
           if (groups['haproxy'] | default([])) | length > 0
           else (('master.' + webitel_patroni_scope + '.service.consul') if ha_mode
                 else ('127.0.0.1' if single_node
                       else hostvars[groups['postgres'][0]].ansible_default_ipv4.address))) }}
webitel_pg_port: "{{ haproxy_pg_rw_port if webitel_pg_haproxy else 5432 }}"
```

- [ ] **Step 2: Замінити `webitel_pg_host` (warm-standby — DC-aware вибір haproxy-ноди)**

У `inventories/warm-standby-2dc.example/group_vars/all/main.yml` замінити блок `webitel_pg_host` на DC-aware варіант (узгоджено з тамтешньою логікою `_opensips_dc_hosts`):

```yaml
haproxy_pg_rw_port: 6432
haproxy_pg_ro_port: 6433
webitel_pg_haproxy: "{{ (groups['haproxy'] | default([])) | length > 0 }}"
_haproxy_dc_hosts: >-
  {{ groups['haproxy'] | default([]) | map('extract', hostvars)
     | selectattr('datacenter', 'defined')
     | selectattr('datacenter', '==', datacenter | default('dc1'))
     | map(attribute='inventory_hostname') | list }}
webitel_pg_host: >-
  {{ '127.0.0.1' if inventory_hostname in (groups['haproxy'] | default([]))
     else (hostvars[(_haproxy_dc_hosts or groups['haproxy'])[0]].ansible_default_ipv4.address
           if (groups['haproxy'] | default([])) | length > 0
           else (('master.' + webitel_patroni_scope + '.service.consul') if ha_mode
                 else ('127.0.0.1' if single_node
                       else hostvars[groups['postgres'][0]].ansible_default_ipv4.address))) }}
webitel_pg_port: "{{ haproxy_pg_rw_port if webitel_pg_haproxy else 5432 }}"
```

- [ ] **Step 3: Оновити `webitel_pg_dsn_base` і додати `webitel_pg_dsn_replicas` (усі 5 файлів)**

У кожному з 5 файлів замінити рядок
`webitel_pg_dsn_base: "postgres://opensips:webitel@{{ webitel_pg_host }}:5432/webitel"`
на:

```yaml
webitel_pg_dsn_base: "postgres://opensips:webitel@{{ webitel_pg_host }}:{{ webitel_pg_port }}/webitel"
webitel_pg_dsn_replicas: >-
  {{ ('postgres://opensips:webitel@' + webitel_pg_host + ':' + (haproxy_pg_ro_port | string) + '/webitel')
     if webitel_pg_haproxy else webitel_pg_dsn_base }}
```

- [ ] **Step 4: yamllint**

Run: `yamllint inventories/*/group_vars/all/main.yml`
Expected: no errors

- [ ] **Step 5: syntax-check (без регресій парсингу vars)**

Run: `ansible-playbook -i inventories/failover.example site.yml --syntax-check`
Expected: exit 0

- [ ] **Step 6: Stage**

```bash
git add inventories/*/group_vars/all/main.yml
```

---

## Task 9: Оновити споживачів rw-порту (opensips, grafana)

**Files:**
- Modify: `roles/opensips/tasks/configure.yml`
- Modify: `roles/grafana/tasks/configure.yml`

- [ ] **Step 1: opensips — порт у regex**

У `roles/opensips/tasks/configure.yml`, задача `Set PostgreSQL host address in opensips.cfg (multi-node)` — замінити:

```yaml
    regexp: '(postgres://opensips:webitel@)[^:]*(:5432)'
    replace: '\1{{ webitel_pg_host }}\2'
```
на:
```yaml
    regexp: '(postgres://opensips:webitel@)[^:]+:\d+'
    replace: '\1{{ webitel_pg_host }}:{{ webitel_pg_port }}'
```

- [ ] **Step 2: grafana — порт у datasource URL**

У `roles/grafana/tasks/configure.yml`, у вмісті datasource — замінити:

```yaml
          url: "{{ webitel_pg_host }}:5432"
```
на:
```yaml
          url: "{{ webitel_pg_host }}:{{ webitel_pg_port }}"
```

- [ ] **Step 3: yamllint**

Run: `yamllint roles/opensips/tasks/configure.yml roles/grafana/tasks/configure.yml`
Expected: no errors

- [ ] **Step 4: Stage**

```bash
git add roles/opensips/tasks/configure.yml roles/grafana/tasks/configure.yml
```

---

## Task 10: Вайринг реплік-DSN у сервіси (engine, call_center, flow_manager, storage)

**Files:**
- Modify: `roles/webitel_engine/defaults/main.yml`
- Modify: `roles/webitel_call_center/defaults/main.yml`
- Modify: `roles/webitel_flow_manager/defaults/main.yml`
- Modify: `roles/webitel_storage/defaults/main.yml`

Env-ключ підтверджено в сорсах: `SQL_DATA_SOURCE_REPLICAS` (flow_manager/engine/call_center/storage). Для кожного сервісу суфікс query-параметрів дзеркалимо з його ж `DATA_SOURCE`.

- [ ] **Step 1: engine**

У `roles/webitel_engine/defaults/main.yml`, у `webitel_engine_env_defaults`, одразу після рядка `DATA_SOURCE: …` додати:

```yaml
  SQL_DATA_SOURCE_REPLICAS: "{{ webitel_pg_dsn_replicas }}?fallback_application_name=engine&sslmode=disable&connect_timeout=10&search_path=call_center"
```

- [ ] **Step 2: call_center**

У `roles/webitel_call_center/defaults/main.yml`, у `webitel_call_center_env_defaults`, після `DATA_SOURCE: …` додати:

```yaml
  SQL_DATA_SOURCE_REPLICAS: "{{ webitel_pg_dsn_replicas }}?application_name=call_center&sslmode=disable&connect_timeout=10&search_path=call_center"
```

- [ ] **Step 3: flow_manager**

У `roles/webitel_flow_manager/defaults/main.yml`, у env-defaults, після `DATA_SOURCE: …` додати:

```yaml
  SQL_DATA_SOURCE_REPLICAS: "{{ webitel_pg_dsn_replicas }}?sslmode=disable&connect_timeout=10"
```

- [ ] **Step 4: storage**

У `roles/webitel_storage/defaults/main.yml`, у env-defaults, після `DATA_SOURCE: …` додати:

```yaml
  SQL_DATA_SOURCE_REPLICAS: "{{ webitel_pg_dsn_replicas }}?application_name=storage&sslmode=disable&connect_timeout=10"
```

- [ ] **Step 5: Перевірити точну назву ключа в env-defaults кожної ролі**

Run: `grep -rn "SQL_DATA_SOURCE_REPLICAS\|DATA_SOURCE:" roles/webitel_engine/defaults roles/webitel_call_center/defaults roles/webitel_flow_manager/defaults roles/webitel_storage/defaults`
Expected: кожна роль має і `DATA_SOURCE:`/`DATASOURCE`-аналог, і доданий `SQL_DATA_SOURCE_REPLICAS:` під ним, у тому ж dict.

> Примітка: ключ йде в той самий `*_env_defaults` dict, який роль застосовує через `lineinfile` loop по `dict2items` — нічого більше міняти не треба.

- [ ] **Step 6: yamllint**

Run: `yamllint roles/webitel_engine/defaults/main.yml roles/webitel_call_center/defaults/main.yml roles/webitel_flow_manager/defaults/main.yml roles/webitel_storage/defaults/main.yml`
Expected: no errors

- [ ] **Step 7: Stage**

```bash
git add roles/webitel_engine/defaults/main.yml roles/webitel_call_center/defaults/main.yml roles/webitel_flow_manager/defaults/main.yml roles/webitel_storage/defaults/main.yml
```

---

## Task 11: Демо sidecar у failover-інвентарі

**Files:**
- Modify: `inventories/failover.example/01-hosts.yml`

- [ ] **Step 1: Додати `haproxy` у services кожного app-хоста**

У `inventories/failover.example/01-hosts.yml` додати `haproxy` у список `services` для `ha1`, `ha2`, `ha3` (sidecar — локальний проксі на кожній ноді, де крутяться сервіси з доступом до БД). Наприклад, для `ha1` — у його `services:` додати рядок:

```yaml
        - haproxy
```
(аналогічно у `ha2` і `ha3`).

> Альтернатива (dedicated): не додавати у app-хости, а виділити окремий хост зі `services: [consul_agent, nomad_client, haproxy]`. Для прикладу лишаємо sidecar.

- [ ] **Step 2: Перевірити, що inventory парситься і група наповнюється**

Run: `ansible-inventory -i inventories/failover.example --graph haproxy`
Expected: під `@haproxy:` перелічені `ha1`, `ha2`, `ha3`

- [ ] **Step 3: Stage**

```bash
git add inventories/failover.example/01-hosts.yml
```

---

## Task 12: Повна перевірка (lint + syntax + рендер)

**Files:** (без змін — лише перевірки)

- [ ] **Step 1: yamllint по всьому, що чіпали**

Run: `yamllint roles/haproxy playbooks inventories`
Expected: exit 0

- [ ] **Step 2: ansible-lint**

Run: `ansible-lint roles/haproxy playbooks/database.yml`
Expected: `Passed` (профіль production; 0 violations). Якщо `shell` у configure.yml дає `command-instead-of-shell` — це очікувано через редирект `>`, лишити (редирект потребує shell); за потреби додати `# noqa` із поясненням.

- [ ] **Step 3: syntax-check повного site.yml на двох інвентарях**

Run: `ansible-playbook -i inventories/failover.example site.yml --syntax-check && ansible-playbook -i inventories/singlehost.example site.yml --syntax-check`
Expected: обидва exit 0 (підтверджує, що зміни vars не ламають не-HA інвентар, де `webitel_pg_haproxy=false`)

- [ ] **Step 4: `[VM]` Рендер haproxy.cfg на живому хості**

На Debian-VM з розгорнутим Patroni + інвентарем failover:
Run: `ansible-playbook -i <inv> playbooks/database.yml --tags haproxy_configure --check --diff --limit ha1`
Expected: diff показує валідний `/etc/haproxy/haproxy.cfg` із `listen postgres-rw`/`postgres-ro`, бекендами по всіх patroni-нодах, `check port 8008`, і (при TLS) `check-ssl crt … ca-file …`.

- [ ] **Step 5: `[VM]` Функціональна перевірка з'єднання**

На VM після повного прогону:
Run (на app-хості): `psql "postgres://opensips:webitel@127.0.0.1:6432/webitel" -c "SELECT pg_is_in_recovery();"`
Expected: `f` (rw-порт веде на лідера). Аналогічно `:6433` → `t` (репліка).

- [ ] **Step 6: Stage будь-яких правок з ревʼю**

```bash
git add -A
```

---

## Фінальний чекпойнт

- [ ] Усі задачі виконані, lint/syntax зелені, `[VM]`-кроки підтверджені (або свідомо відкладені).
- [ ] **Запитати користувача дозвіл на коміт** (project rule — без явного «ок» не комітити). Тоді одним комітом:

```bash
git commit -m "feat(haproxy): add HAProxy LB in front of Patroni (rw/ro, sidecar+dedicated)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```
