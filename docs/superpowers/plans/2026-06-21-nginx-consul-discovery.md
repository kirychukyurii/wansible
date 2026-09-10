# nginx → Consul DNS discovery (Блок 3.2) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** nginx-апстріми через Consul DNS із runtime-резолвом (фейловер без reload): backend-імена в nginx-змінні (`$storage_backend` тощо), resolver `127.0.0.1:8600`, proxy_pass на `$var`; + 2 Consul prepared queries для api/messages-bot.

**Architecture:** Дефолти `nginx_upstream_*` видають імʼя nginx-змінної (multi) / `127.0.0.1` (single) — наявні `replace`-таски вже вставляють їх у завантажений конфіг. `resolver` + http-level `map` (визначення backend-імен) інжектимо `blockinfile`-ом на початок `sites-enabled/default`. consul-роль ідемпотентно створює prepared queries `webitel-api`→`go.webitel.api`, `webitel-messages-bot`→`webitel.chat.bot`. single_node лишається на 127.0.0.1. grafana/opensips/portal — без consul (nomad later / localhost).

**Tech Stack:** Ansible (ansible-core), nginx `resolver`/`map`/variable `proxy_pass`, Consul prepared queries (HTTP API), Jinja2, yamllint, ansible-lint.

**Спека:** [docs/superpowers/specs/2026-06-21-nginx-consul-discovery-design.md](../specs/2026-06-21-nginx-consul-discovery-design.md)

---

## Файлова структура

- **Modify:** `roles/nginx/defaults/main.yml` — 5 upstream-дефолтів → `$backend` (multi) / `127.0.0.1` (single).
- **Modify:** `roles/nginx/tasks/configure.yml` — `blockinfile` (resolver + 5 map) на BOF `sites-enabled/default`, `when: not single_node`.
- **Create:** `roles/consul/tasks/prepared_queries.yml` — 2 ідемпотентні prepared queries.
- **Modify:** `roles/consul/tasks/main.yml` — інклуд `prepared_queries.yml`.
- **Modify:** `roles/nginx/README.md` — розділ про Consul discovery.
- **Не чіпаємо:** grafana-апстрім (IP, nomad later), portal grpc (127.0.0.1:10028), single_node-шлях, наявні regexp-и replace-тасків (лише дефолти міняються).

---

## Task 1: nginx defaults → `$backend`-змінні

**Files:**
- Modify: `roles/nginx/defaults/main.yml`

- [ ] **Step 1: Замінити 5 upstream-дефолтів**

У `roles/nginx/defaults/main.yml` замінити поточні `nginx_upstream_storage/api/messages/engine_ws/opensips` на:

```yaml
nginx_upstream_storage: >-
  {{ '127.0.0.1' if single_node else '$storage_backend' }}
nginx_upstream_api: >-
  {{ '127.0.0.1' if single_node else '$webitel_api_backend' }}
nginx_upstream_messages: >-
  {{ '127.0.0.1' if single_node else '$messages_bot_backend' }}
nginx_upstream_engine_ws: >-
  {{ '127.0.0.1' if single_node else '$engine_backend' }}
nginx_upstream_opensips: >-
  {{ '127.0.0.1' if single_node else '$opensips_backend' }}
```

`nginx_upstream_grafana` лишити без змін (IP-based — grafana через nomad-джобу пізніше).

- [ ] **Step 2: yamllint**

Run:
```bash
yamllint roles/nginx/defaults/main.yml
```
Expected: без помилок.

- [ ] **Step 3: Commit**

```bash
git add roles/nginx/defaults/main.yml
git commit -m "feat(nginx): emit consul backend variables for upstreams"
```

---

## Task 2: blockinfile resolver+map у configure.yml

**Files:**
- Modify: `roles/nginx/tasks/configure.yml`

- [ ] **Step 1: Додати blockinfile одразу після завантаження site-конфіга**

У `roles/nginx/tasks/configure.yml`, ПІСЛЯ таска «Download nginx default site (first run only)» і ПЕРЕД першим `replace`-таском, додати:

```yaml
- name: Inject Consul resolver and backend maps (multi-host)
  ansible.builtin.blockinfile:
    path: /etc/nginx/sites-enabled/default
    insertbefore: BOF
    marker: "# {mark} ANSIBLE MANAGED — webitel consul discovery"
    block: |
      resolver 127.0.0.1:8600 valid=3s ipv6=off;
      map $host $webitel_api_backend   { default webitel-api.query.consul; }
      map $host $storage_backend       { default storage.service.consul; }
      map $host $messages_bot_backend  { default webitel-messages-bot.query.consul; }
      map $host $engine_backend        { default engine.service.consul; }
      map $host $opensips_backend      { default opensips.service.consul; }
  when: not single_node | default(false)
  notify: restart nginx
```

(Решта `replace`-тасків без змін — вони вставляють `{{ nginx_upstream_X }}` з Task 1.)

- [ ] **Step 2: Верифікація патчів на фікстурі shipped-конфіга**

Фікстура збережена в `<scratchpad>/nginx-fixture/default`. Створити throwaway `_nginx_patch_check.yml` у корені репо:

```yaml
---
- hosts: localhost
  gather_facts: false
  vars:
    single_node: false
    webitel_storage_public_port: 10037
    webitel_messages_bot_port: 10040
    webitel_engine_websocket_port: 10031
    nginx_upstream_storage: "$storage_backend"
    nginx_upstream_api: "$webitel_api_backend"
    nginx_upstream_messages: "$messages_bot_backend"
    nginx_upstream_engine_ws: "$engine_backend"
    nginx_upstream_opensips: "$opensips_backend"
    _fixture: "{{ lookup('env', 'NGINX_FIXTURE') }}"
  tasks:
    - name: Inject Consul resolver and backend maps (multi-host)
      ansible.builtin.blockinfile:
        path: "{{ _fixture }}"
        insertbefore: BOF
        marker: "# {mark} ANSIBLE MANAGED — webitel consul discovery"
        block: |
          resolver 127.0.0.1:8600 valid=3s ipv6=off;
          map $host $webitel_api_backend   { default webitel-api.query.consul; }
          map $host $storage_backend       { default storage.service.consul; }
          map $host $messages_bot_backend  { default webitel-messages-bot.query.consul; }
          map $host $engine_backend        { default engine.service.consul; }
          map $host $opensips_backend      { default opensips.service.consul; }
    - name: Storage proxy_pass + POST map
      ansible.builtin.replace:
        path: "{{ _fixture }}"
        regexp: '(proxy_pass http://)127\.0\.0\.1:10023;'
        replace: '\g<1>{{ nginx_upstream_storage }}:{{ webitel_storage_public_port }};'
    - name: Storage POST map value
      ansible.builtin.replace:
        path: "{{ _fixture }}"
        regexp: '(^.*POST.*)(\s"127\.0\.0\.1:10023")(.*$)'
        replace: '\1 "{{ nginx_upstream_storage }}:{{ webitel_storage_public_port }}"\3'
    - name: API proxy_pass
      ansible.builtin.replace:
        path: "{{ _fixture }}"
        regexp: '(^.*)(http://127\.0\.0\.1)(:8080;)$'
        replace: '\1http://{{ nginx_upstream_api }}\3'
    - name: API default map value
      ansible.builtin.replace:
        path: "{{ _fixture }}"
        regexp: '(^.*default.*)(\s"127\.0\.0\.1:8080")(.*$)'
        replace: '\1 "{{ nginx_upstream_api }}:8080"\3'
    - name: Messages proxy_pass
      ansible.builtin.replace:
        path: "{{ _fixture }}"
        regexp: '(proxy_pass http://)127\.0\.0\.1:10031;'
        replace: '\g<1>{{ nginx_upstream_messages }}:{{ webitel_messages_bot_port }};'
    - name: Engine WS proxy_pass
      ansible.builtin.replace:
        path: "{{ _fixture }}"
        regexp: '(proxy_pass http://)127\.0\.0\.1:10022;'
        replace: '\g<1>{{ nginx_upstream_engine_ws }}:{{ webitel_engine_websocket_port }};'
    - name: OpenSIPS proxy_pass
      ansible.builtin.replace:
        path: "{{ _fixture }}"
        regexp: '(^.*)(http://127\.0\.0\.1)(:5070;)$'
        replace: '\1http://{{ nginx_upstream_opensips }}\3'
```

Run:
```bash
F=/private/tmp/claude-501/-Users-kirychuk-Documents-goland-wansible/5700bcda-fcb0-4e95-b3b8-2e906e52a9bd/scratchpad/nginx-fixture/default
cp "$F" "${F}.orig"
NGINX_FIXTURE="$F" ansible-playbook _nginx_patch_check.yml >/dev/null 2>&1
echo "=== патчений конфіг ==="; cat "$F"
echo "=== перевірки ==="
grep -q 'resolver 127.0.0.1:8600' "$F" && echo "resolver OK"
grep -q 'proxy_pass http://\$storage_backend:10037;' "$F" && echo "storage OK"
grep -q 'proxy_pass http://\$webitel_api_backend:8080;' "$F" && echo "api OK"
grep -q '"\$storage_backend:10037"' "$F" && echo "api_backend POST map OK"
grep -q '"\$webitel_api_backend:8080"' "$F" && echo "api_backend default map OK"
grep -q 'proxy_pass http://\$messages_bot_backend:10040;' "$F" && echo "messages OK"
grep -q 'proxy_pass http://\$engine_backend:10031;' "$F" && echo "engine OK"
grep -q 'proxy_pass http://\$opensips_backend:5070;' "$F" && echo "opensips OK"
grep -q 'proxy_pass http://127.0.0.1:3000;' "$F" && echo "grafana lishylos IP OK"
cp "${F}.orig" "$F"   # відновити фікстуру для повторних прогонів
```
Expected: усі перевірки `OK`; grafana лишився `127.0.0.1:3000`.

- [ ] **Step 3: Прибрати throwaway + лінт**

Run:
```bash
rm _nginx_patch_check.yml
yamllint roles/nginx/tasks/configure.yml
ansible-lint roles/nginx/
```
Expected: yamllint без помилок; роль nginx profile production passed.

- [ ] **Step 4: Commit**

```bash
git add roles/nginx/tasks/configure.yml
git commit -m "feat(nginx): inject Consul resolver and backend maps"
```

---

## Task 3: Consul prepared queries

**Files:**
- Create: `roles/consul/tasks/prepared_queries.yml`
- Modify: `roles/consul/tasks/main.yml`

- [ ] **Step 1: Створити `roles/consul/tasks/prepared_queries.yml`**

```yaml
---
# Prepared queries — чистий DNS-alias на go-micro-сервіси з DNS-недружніми іменами
# (go.webitel.api / webitel.chat.bot). nginx резолвить webitel-api.query.consul /
# webitel-messages-bot.query.consul. POST не ідемпотентний → спершу GET за Name.
- name: Get existing Consul prepared queries
  ansible.builtin.uri:
    url: http://127.0.0.1:8500/v1/query
    method: GET
    return_content: true
  register: _consul_queries
  run_once: true
  delegate_to: "{{ groups['consul_server'][0] }}"

- name: Create Consul prepared queries (if absent)
  ansible.builtin.uri:
    url: http://127.0.0.1:8500/v1/query
    method: POST
    body_format: json
    body:
      Name: "{{ item.name }}"
      Service:
        Service: "{{ item.service }}"
        OnlyPassing: true
    status_code: 200
  loop:
    - { name: "webitel-api", service: "go.webitel.api" }
    - { name: "webitel-messages-bot", service: "webitel.chat.bot" }
  loop_control:
    label: "{{ item.name }}"
  when: item.name not in (_consul_queries.json | map(attribute='Name') | list)
  run_once: true
  delegate_to: "{{ groups['consul_server'][0] }}"
```

- [ ] **Step 2: Підключити у `roles/consul/tasks/main.yml`**

Додати в кінець:

```yaml
- name: Create Consul prepared queries (multi-host)
  ansible.builtin.include_tasks:
    file: prepared_queries.yml
    apply:
      tags: [consul_queries]
  when: not single_node | default(false)
  tags: [consul_queries]
```

- [ ] **Step 3: yamllint + ansible-lint**

Run:
```bash
yamllint roles/consul/tasks/prepared_queries.yml roles/consul/tasks/main.yml
ansible-lint roles/consul/
```
Expected: yamllint без помилок; роль consul profile production passed.

- [ ] **Step 4: Syntax-check**

Run:
```bash
for inv in singlehost multihost failover warm-standby-2dc; do
  ansible-playbook --syntax-check -i "inventories/${inv}.example" site.yml >/dev/null 2>&1 && echo "$inv OK" || echo "$inv FAIL"
done
```
Expected: усі чотири OK.

- [ ] **Step 5: Commit**

```bash
git add roles/consul/tasks/prepared_queries.yml roles/consul/tasks/main.yml
git commit -m "feat(consul): create prepared queries for webitel-api and messages-bot"
```

---

## Task 4: Документація

**Files:**
- Modify: `roles/nginx/README.md`

- [ ] **Step 1: Додати розділ у `roles/nginx/README.md`**

Додати (після опису upstream-патчів):

```markdown
## Consul discovery (multi-host)

У multi-host nginx резолвить апстріми через Consul DNS у runtime (фейловер без reload):
backend-імена визначені як nginx-змінні (`$storage_backend` тощо) через http-level `map`,
вписані `blockinfile`-ом на початок `sites-enabled/default` разом із
`resolver 127.0.0.1:8600`. `proxy_pass` використовує ці змінні → nginx перерезолвлює
за `valid=3s`.

| Апстрім | Consul-імʼя |
|---|---|
| storage | `storage.service.consul` |
| api/core | `webitel-api.query.consul` (prepared query → `go.webitel.api`) |
| messages bot | `webitel-messages-bot.query.consul` (prepared query → `webitel.chat.bot`) |
| engine WS | `engine.service.consul` |
| opensips | `opensips.service.consul` (реєструється nomad-джобою) |

Prepared queries створює роль `consul` (`prepared_queries.yml`). grafana і portal-grpc
лишаються на прямих адресах. single_node лишається на `127.0.0.1`.
```

- [ ] **Step 2: Commit**

```bash
git add roles/nginx/README.md
git commit -m "docs(nginx): document Consul discovery for upstreams"
```

---

## Фінальна верифікація (вся фіча разом)

- [ ] **Лінт + syntax-check (як у CI; топологічні var-naming — pre-existing)**

Run:
```bash
yamllint roles/nginx/ roles/consul/
ansible-lint roles/nginx/ roles/consul/
for inv in singlehost multihost failover warm-standby-2dc; do
  ansible-playbook --syntax-check -i "inventories/${inv}.example" site.yml >/dev/null 2>&1 && echo "$inv OK" || echo "$inv FAIL"
done
```
Expected: yamllint без помилок; ролі nginx/consul profile production passed; усі syntax-check OK.

- [ ] **(На реальному кластері) підтвердити резолв і конфіг**

Run на nginx-ноді:
```bash
dig @127.0.0.1 -p 8600 webitel-api.query.consul +short        # IP core
dig @127.0.0.1 -p 8600 storage.service.consul +short          # IP storage
dig @127.0.0.1 -p 8600 engine.service.consul +short           # IP engine
grep -E 'resolver|proxy_pass http://\$' /etc/nginx/sites-enabled/default
nginx -t
```
Expected: query/service резолвляться; proxy_pass використовують `$backend`-змінні; `nginx -t` → ok.
```
