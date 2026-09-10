# Webitel Service Tunables Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Зробити порти-listener-и та service-specific параметри webitel-сервісів конфігурованими через типізовані namespaced vars (firewall-driven), зберігши узгодженість з nginx.

**Architecture:** Дефолти listener-портів (єдиний блок 10030–10043) і DSN/AMQP-тюнінгу живуть у `roles/topology/defaults` і заморожуються фактами в `roles/topology/tasks/main.yml` (cross-role single source of truth, як `pki_remote_dir`). Сервіс-spec-и в `roles/webitel_service/vars/services/*.yml` рендерять ці факти/knob-и у відповідні env-ключі. nginx-роль переписує хост **і порт** трьох proxied-upstream-ів з тих самих фактів. Override — namespaced var у `group_vars/host_vars` (той самий precedence-патерн, що скрізь у репо).

**Tech Stack:** Ansible (ansible-core 2.21), Jinja2, YAML. Верифікація: `yamllint`, `ansible-lint`, `ansible-playbook --syntax-check`, офлайн-рендер vars через тимчасовий плейбук на `localhost,`.

> **Коміти:** проєкт працює в режимі «не комітити без явного дозволу користувача» (фази 1+2 досі в робочому дереві без комітів). Тому кроки нижче **НЕ** містять `git commit`. Кожен таск завершується валідацією (lint + офлайн-рендер). Користувач оформить коміти пакетно, коли скаже.

**Spec:** `docs/superpowers/specs/2026-06-17-webitel-service-tunables-design.md`

---

## File Structure

**Modify:**
- `roles/topology/defaults/main.yml` — додати 14 port-дефолтів + `webitel_pg_sslmode`/`webitel_pg_connect_timeout`/`webitel_amqp_heartbeat`.
- `roles/topology/tasks/main.yml` — новий `set_fact`-таск, що заморожує ці значення у факти.
- `roles/webitel_service/vars/services/{engine,call_center,flow_manager,storage,messages,logger,cases,media_exporter,core}.yml` — параметризувати env.
- `roles/nginx/tasks/configure.yml` — переписувати хост+порт для engine_ws/storage/messages; прибрати `when: not single_node` для цих трьох.
- `inventories/multihost.example/group_vars/all/main.yml` — закоментовані приклади knob-ів.
- `roles/webitel_service/README.md` — таблиця knob-ів + port-мапа.

**Create (тимчасовий, видаляється в кінці):**
- `/tmp/verify-tunables.yml` — офлайн-рендер-перевірка значень env.

**Без змін:** `roles/webitel_service/tasks/main.yml` (механізм lineinfile вже додає нові ключі — regexp не матчиться → рядок додається), `roles/webitel_service/defaults/main.yml` (`webitel_service_env_extra` лишається escape-hatch), nginx upstream-и api/opensips/grafana/portal.

---

## Port block (reference)

| env-ключ | knob (= topology fact) | порт | nginx |
|---|---|---|---|
| engine `GRPC_PORT` | `webitel_engine_grpc_port` | 10030 | |
| engine `WEBSOCKET` | `webitel_engine_websocket_port` | 10031 | ✓ |
| call_center `GRPC_PORT` | `webitel_call_center_grpc_port` | 10032 | |
| flow_manager `GRPC_PORT` | `webitel_flow_manager_grpc_port` | 10033 | |
| flow_manager `WEB_ADDR` | `webitel_flow_manager_web_port` | 10034 | |
| flow_manager `ELSE_PORT` | `webitel_flow_manager_esl_port` | 10035 | |
| storage `GRPC_PORT` | `webitel_storage_grpc_port` | 10036 | |
| storage `PUBLIC_ADDRESS` | `webitel_storage_public_port` | 10037 | ✓ |
| storage `INTERNAL_ADDRESS` | `webitel_storage_internal_port` | 10038 | |
| messages `MICRO_SERVICE_ADDRESS` | `webitel_messages_service_port` | 10039 | |
| messages `WEBITEL_BOT_ADDRESS` | `webitel_messages_bot_port` | 10040 | ✓ |
| logger `GRPC_ADDR` (inline) | `webitel_logger_grpc_port` | 10041 | |
| cases `GRPC_ADDR` (inline) | `webitel_cases_grpc_port` | 10042 | |
| media_exporter `GRPC_ADDR` (inline) | `webitel_media_exporter_grpc_port` | 10043 | |

DSN/AMQP cluster-defaults: `webitel_pg_sslmode=disable`, `webitel_pg_connect_timeout=10`, `webitel_amqp_heartbeat=10`. Per-service override: `webitel_<svc>_pg_sslmode` / `_pg_connect_timeout` / `_amqp_heartbeat` (optional group_vars).
Log level: `webitel_<svc>_log_level | default(webitel_log_level | default('<upstream>'))` — upstream `debug` (LOG_LVL services), `info` (messages WBTL_LOG_LEVEL), `trace` (core MICRO_LOG_LEVEL). logger/cases/media_exporter — log-ключа немає.

---

### Task 1: Topology — defaults + freeze facts + verify scaffold

**Files:**
- Modify: `roles/topology/defaults/main.yml`
- Modify: `roles/topology/tasks/main.yml`
- Create: `/tmp/verify-tunables.yml`

- [ ] **Step 1: Add tunable defaults to topology defaults**

У кінець `roles/topology/defaults/main.yml` додати:

```yaml

# --- Webitel service tunables (єдине джерело істини, заморожуються фактами) ---
# DSN/AMQP тюнінг: кластерний дефолт. Перебивається per-service knob-ом
# (webitel_<svc>_pg_sslmode / _pg_connect_timeout / _amqp_heartbeat) у group_vars.
webitel_pg_sslmode: disable
webitel_pg_connect_timeout: 10
webitel_amqp_heartbeat: 10

# Listener-порти всіх webitel-сервісів — єдиний firewall-блок 10030–10043.
# Перевизначається в group_vars/host_vars тим самим ім'ям. nginx споживає
# 10031/10037/10040 (engine WS / storage public / messages bot) як ті самі факти.
webitel_engine_grpc_port: 10030
webitel_engine_websocket_port: 10031
webitel_call_center_grpc_port: 10032
webitel_flow_manager_grpc_port: 10033
webitel_flow_manager_web_port: 10034
webitel_flow_manager_esl_port: 10035
webitel_storage_grpc_port: 10036
webitel_storage_public_port: 10037
webitel_storage_internal_port: 10038
webitel_messages_service_port: 10039
webitel_messages_bot_port: 10040
webitel_logger_grpc_port: 10041
webitel_cases_grpc_port: 10042
webitel_media_exporter_grpc_port: 10043
```

- [ ] **Step 2: Freeze them as facts in topology tasks**

У `roles/topology/tasks/main.yml`, **одразу після** таска `- name: Freeze global credentials and shared paths` (секція 2), додати новий таск:

```yaml

# --- 2b. Webitel service tunables → факти (доступні в усіх ролях: webitel_service, nginx) ---
# Той самий патерн, що для кредів: RHS читає group_vars-or-default (defaults цієї ролі),
# set_fact (precedence 18) робить значення видимим поза topology. Override у group_vars
# працює, бо RHS резолвиться ДО заморозки.
- name: Freeze webitel service tunable defaults
  ansible.builtin.set_fact:
    webitel_pg_sslmode: "{{ webitel_pg_sslmode }}"
    webitel_pg_connect_timeout: "{{ webitel_pg_connect_timeout }}"
    webitel_amqp_heartbeat: "{{ webitel_amqp_heartbeat }}"
    webitel_engine_grpc_port: "{{ webitel_engine_grpc_port }}"
    webitel_engine_websocket_port: "{{ webitel_engine_websocket_port }}"
    webitel_call_center_grpc_port: "{{ webitel_call_center_grpc_port }}"
    webitel_flow_manager_grpc_port: "{{ webitel_flow_manager_grpc_port }}"
    webitel_flow_manager_web_port: "{{ webitel_flow_manager_web_port }}"
    webitel_flow_manager_esl_port: "{{ webitel_flow_manager_esl_port }}"
    webitel_storage_grpc_port: "{{ webitel_storage_grpc_port }}"
    webitel_storage_public_port: "{{ webitel_storage_public_port }}"
    webitel_storage_internal_port: "{{ webitel_storage_internal_port }}"
    webitel_messages_service_port: "{{ webitel_messages_service_port }}"
    webitel_messages_bot_port: "{{ webitel_messages_bot_port }}"
    webitel_logger_grpc_port: "{{ webitel_logger_grpc_port }}"
    webitel_cases_grpc_port: "{{ webitel_cases_grpc_port }}"
    webitel_media_exporter_grpc_port: "{{ webitel_media_exporter_grpc_port }}"
```

- [ ] **Step 3: Create the offline render-verify playbook (failing test)**

Створити `/tmp/verify-tunables.yml`. Він НЕ запускає topology (щоб не тягнути facts/inventory), а вантажить `roles/topology/defaults/main.yml` як `vars_files` (ті самі дефолти) і стабить connection-факти, потім `include_vars` кожного spec-а і перевіряє рендер. `REPO` нижче — абсолютний шлях до репо (підставити при запуску, напр. `/Users/kirychuk/Documents/goland/wansible`).

```yaml
---
- name: Verify webitel service tunables render
  hosts: localhost
  gather_facts: false
  vars:
    single_node: true
    webitel_consul_address: "127.0.0.1"
    webitel_amqp_url: "amqp://webitel:webitel@127.0.0.1:5672"
    webitel_pg_dsn_base: "postgres://opensips:webitel@127.0.0.1:5432/webitel"
    webitel_pg_dsn_replicas: "postgres://opensips:webitel@127.0.0.1:5432/webitel"
    webitel_opensips_host: "127.0.0.1"
    webitel_public_url: "http://localhost"
  vars_files:
    - "{{ repo }}/roles/topology/defaults/main.yml"
  tasks:
    - name: engine
      block:
        - ansible.builtin.include_vars:
            file: "{{ repo }}/roles/webitel_service/vars/services/engine.yml"
        - ansible.builtin.assert:
            that:
              - webitel_service_spec.env.GRPC_PORT | string == '10030'
              - webitel_service_spec.env.WEBSOCKET == ':10031'
              - "'sslmode=disable' in webitel_service_spec.env.DATA_SOURCE"
              - "'connect_timeout=10' in webitel_service_spec.env.DATA_SOURCE"
              - "'heartbeat=10' in webitel_service_spec.env.AMQP"
              - webitel_service_spec.env.LOG_LVL == 'debug'
```

- [ ] **Step 4: Run verify — expect FAIL (engine spec not yet updated)**

Run: `ansible-playbook /tmp/verify-tunables.yml -i localhost, -e repo=$PWD`
Expected: FAIL на assert (engine.yml ще має старий env без `GRPC_PORT`/`WEBSOCKET`/`LOG_LVL`, тому ключі undefined → assert падає). Це підтверджує, що тест робочий.

- [ ] **Step 5: Lint topology changes**

Run: `yamllint roles/topology/ && ansible-lint roles/topology`
Expected: 0 порушень.

---

### Task 2: engine spec

**Files:**
- Modify: `roles/webitel_service/vars/services/engine.yml`

- [ ] **Step 1: Replace the env block**

Замінити блок `env:` у `roles/webitel_service/vars/services/engine.yml` на:

```yaml
  env:
    CONSUL: "{{ webitel_consul_address }}:8500"
    AMQP: "{{ webitel_amqp_url }}?heartbeat={{ webitel_engine_amqp_heartbeat | default(webitel_amqp_heartbeat) }}"
    DATA_SOURCE: "{{ webitel_pg_dsn_base }}?fallback_application_name=engine&sslmode={{ webitel_engine_pg_sslmode | default(webitel_pg_sslmode) }}&connect_timeout={{ webitel_engine_pg_connect_timeout | default(webitel_pg_connect_timeout) }}&search_path=call_center"
    SQL_DATA_SOURCE_REPLICAS: "{{ webitel_pg_dsn_replicas }}?fallback_application_name=engine&sslmode={{ webitel_engine_pg_sslmode | default(webitel_pg_sslmode) }}&connect_timeout={{ webitel_engine_pg_connect_timeout | default(webitel_pg_connect_timeout) }}&search_path=call_center"
    OPEN_SIP_ADDR: "{{ webitel_opensips_host }}"
    SIP_PROXY_ADDR: "sip:{{ webitel_opensips_host }}"
    GRPC_ADDR: "{{ '127.0.0.1' if single_node | default(false) else ansible_facts.default_ipv4.address }}"
    GRPC_PORT: "{{ webitel_engine_grpc_port }}"
    WEBSOCKET: ":{{ webitel_engine_websocket_port }}"
    PUBLIC_HOST: "{{ webitel_public_url }}"
    LOG_LVL: "{{ webitel_engine_log_level | default(webitel_log_level | default('debug')) }}"
```

- [ ] **Step 2: Run verify — expect PASS**

Run: `ansible-playbook /tmp/verify-tunables.yml -i localhost, -e repo=$PWD`
Expected: PASS (engine block).

- [ ] **Step 3: Lint**

Run: `yamllint roles/webitel_service/vars/services/engine.yml`
Expected: 0 порушень.

---

### Task 3: call_center spec

**Files:**
- Modify: `roles/webitel_service/vars/services/call_center.yml`

- [ ] **Step 1: Add the assert to verify playbook (failing test)**

У `/tmp/verify-tunables.yml`, після `engine`-блоку додати таск:

```yaml
    - name: call_center
      block:
        - ansible.builtin.include_vars:
            file: "{{ repo }}/roles/webitel_service/vars/services/call_center.yml"
        - ansible.builtin.assert:
            that:
              - webitel_service_spec.env.GRPC_PORT | string == '10032'
              - webitel_service_spec.env.ENABLE_OMNICHANNEL | string == '0'
              - "'sslmode=disable' in webitel_service_spec.env.DATA_SOURCE"
              - webitel_service_spec.env.LOG_LVL == 'debug'
```

- [ ] **Step 2: Run verify — expect FAIL on call_center**

Run: `ansible-playbook /tmp/verify-tunables.yml -i localhost, -e repo=$PWD`
Expected: FAIL на call_center assert.

- [ ] **Step 3: Replace the env block**

```yaml
  env:
    CONSUL: "{{ webitel_consul_address }}:8500"
    AMQP: "{{ webitel_amqp_url }}?heartbeat={{ webitel_call_center_amqp_heartbeat | default(webitel_amqp_heartbeat) }}"
    DATA_SOURCE: "{{ webitel_pg_dsn_base }}?application_name=call_center&sslmode={{ webitel_call_center_pg_sslmode | default(webitel_pg_sslmode) }}&connect_timeout={{ webitel_call_center_pg_connect_timeout | default(webitel_pg_connect_timeout) }}&search_path=call_center"
    SQL_DATA_SOURCE_REPLICAS: "{{ webitel_pg_dsn_replicas }}?application_name=call_center&sslmode={{ webitel_call_center_pg_sslmode | default(webitel_pg_sslmode) }}&connect_timeout={{ webitel_call_center_pg_connect_timeout | default(webitel_pg_connect_timeout) }}&search_path=call_center"
    GRPC_ADDR: "{{ '127.0.0.1' if single_node | default(false) else ansible_facts.default_ipv4.address }}"
    GRPC_PORT: "{{ webitel_call_center_grpc_port }}"
    ENABLE_OMNICHANNEL: "{{ webitel_call_center_omnichannel | default(0) }}"
    LOG_LVL: "{{ webitel_call_center_log_level | default(webitel_log_level | default('debug')) }}"
```

- [ ] **Step 4: Run verify — expect PASS**

Run: `ansible-playbook /tmp/verify-tunables.yml -i localhost, -e repo=$PWD`
Expected: PASS.

- [ ] **Step 5: Lint**

Run: `yamllint roles/webitel_service/vars/services/call_center.yml`
Expected: 0 порушень.

---

### Task 4: flow_manager spec

**Files:**
- Modify: `roles/webitel_service/vars/services/flow_manager.yml`

- [ ] **Step 1: Add assert to verify playbook**

```yaml
    - name: flow_manager
      block:
        - ansible.builtin.include_vars:
            file: "{{ repo }}/roles/webitel_service/vars/services/flow_manager.yml"
        - ansible.builtin.assert:
            that:
              - webitel_service_spec.env.GRPC_PORT | string == '10033'
              - webitel_service_spec.env.WEB_ADDR == '127.0.0.1:10034'
              - webitel_service_spec.env.ELSE_PORT | string == '10035'
              - webitel_service_spec.env.LOG_LVL == 'debug'
```

- [ ] **Step 2: Run verify — expect FAIL on flow_manager**

Run: `ansible-playbook /tmp/verify-tunables.yml -i localhost, -e repo=$PWD`
Expected: FAIL на flow_manager assert.

- [ ] **Step 3: Replace the env block**

```yaml
  env:
    CONSUL: "{{ webitel_consul_address }}:8500"
    AMQP: "{{ webitel_amqp_url }}?heartbeat={{ webitel_flow_manager_amqp_heartbeat | default(webitel_amqp_heartbeat) }}"
    DATA_SOURCE: "{{ webitel_pg_dsn_base }}?sslmode={{ webitel_flow_manager_pg_sslmode | default(webitel_pg_sslmode) }}&connect_timeout={{ webitel_flow_manager_pg_connect_timeout | default(webitel_pg_connect_timeout) }}"
    SQL_DATA_SOURCE_REPLICAS: "{{ webitel_pg_dsn_replicas }}?sslmode={{ webitel_flow_manager_pg_sslmode | default(webitel_pg_sslmode) }}&connect_timeout={{ webitel_flow_manager_pg_connect_timeout | default(webitel_pg_connect_timeout) }}"
    GRPC_ADDR: "{{ '127.0.0.1' if single_node | default(false) else ansible_facts.default_ipv4.address }}"
    GRPC_PORT: "{{ webitel_flow_manager_grpc_port }}"
    WEB_ADDR: "{{ '127.0.0.1' if single_node | default(false) else ansible_facts.default_ipv4.address }}:{{ webitel_flow_manager_web_port }}"
    ELSE_PORT: "{{ webitel_flow_manager_esl_port }}"
    LOG_LVL: "{{ webitel_flow_manager_log_level | default(webitel_log_level | default('debug')) }}"
```

- [ ] **Step 4: Run verify — expect PASS; then lint**

Run: `ansible-playbook /tmp/verify-tunables.yml -i localhost, -e repo=$PWD && yamllint roles/webitel_service/vars/services/flow_manager.yml`
Expected: PASS + 0 порушень.

---

### Task 5: storage spec

**Files:**
- Modify: `roles/webitel_service/vars/services/storage.yml`

- [ ] **Step 1: Add assert to verify playbook**

```yaml
    - name: storage
      block:
        - ansible.builtin.include_vars:
            file: "{{ repo }}/roles/webitel_service/vars/services/storage.yml"
        - ansible.builtin.assert:
            that:
              - webitel_service_spec.env.GRPC_PORT | string == '10036'
              - webitel_service_spec.env.PUBLIC_ADDRESS == ':10037'
              - webitel_service_spec.env.INTERNAL_ADDRESS == ':10038'
              - webitel_service_spec.env.MEDIA_DIRECTORY == '/opt/storage/data'
              - webitel_service_spec.env.TEMP_DIRECTORY == '/var/lib/webitel/storage-temp'
              - webitel_service_spec.env.LOG_LVL == 'debug'
```

- [ ] **Step 2: Run verify — expect FAIL on storage**

Run: `ansible-playbook /tmp/verify-tunables.yml -i localhost, -e repo=$PWD`
Expected: FAIL на storage assert.

- [ ] **Step 3: Replace the env block**

```yaml
  env:
    CONSUL: "{{ webitel_consul_address }}:8500"
    MESSAGE_BROKER_URL: "{{ webitel_amqp_url }}?heartbeat={{ webitel_storage_amqp_heartbeat | default(webitel_amqp_heartbeat) }}"
    DATA_SOURCE: "{{ webitel_pg_dsn_base }}?application_name=storage&sslmode={{ webitel_storage_pg_sslmode | default(webitel_pg_sslmode) }}&connect_timeout={{ webitel_storage_pg_connect_timeout | default(webitel_pg_connect_timeout) }}"
    SQL_DATA_SOURCE_REPLICAS: "{{ webitel_pg_dsn_replicas }}?application_name=storage&sslmode={{ webitel_storage_pg_sslmode | default(webitel_pg_sslmode) }}&connect_timeout={{ webitel_storage_pg_connect_timeout | default(webitel_pg_connect_timeout) }}"
    GRPC_ADDR: "{{ '127.0.0.1' if single_node | default(false) else ansible_facts.default_ipv4.address }}"
    GRPC_PORT: "{{ webitel_storage_grpc_port }}"
    PUBLIC_ADDRESS: ":{{ webitel_storage_public_port }}"
    INTERNAL_ADDRESS: ":{{ webitel_storage_internal_port }}"
    MEDIA_DIRECTORY: "{{ webitel_storage_media_directory | default('/opt/storage/data') }}"
    TEMP_DIRECTORY: "{{ webitel_storage_temp_directory | default('/var/lib/webitel/storage-temp') }}"
    PUBLIC_HOST: "{{ webitel_public_url }}"
    LOG_LVL: "{{ webitel_storage_log_level | default(webitel_log_level | default('debug')) }}"
```

- [ ] **Step 4: Run verify — expect PASS; then lint**

Run: `ansible-playbook /tmp/verify-tunables.yml -i localhost, -e repo=$PWD && yamllint roles/webitel_service/vars/services/storage.yml`
Expected: PASS + 0 порушень.

---

### Task 6: messages spec

**Files:**
- Modify: `roles/webitel_service/vars/services/messages.yml`

- [ ] **Step 1: Add assert to verify playbook**

```yaml
    - name: messages
      block:
        - ansible.builtin.include_vars:
            file: "{{ repo }}/roles/webitel_service/vars/services/messages.yml"
        - ansible.builtin.assert:
            that:
              - webitel_service_spec.env.MICRO_SERVICE_ADDRESS == '127.0.0.1:10039'
              - webitel_service_spec.env.WEBITEL_BOT_ADDRESS == '127.0.0.1:10040'
              - webitel_service_spec.env.WBTL_LOG_LEVEL == 'info'
              - "'sslmode=disable' in webitel_service_spec.env.WEBITEL_DBO_ADDRESS"
```

- [ ] **Step 2: Run verify — expect FAIL on messages**

Run: `ansible-playbook /tmp/verify-tunables.yml -i localhost, -e repo=$PWD`
Expected: FAIL на messages assert.

- [ ] **Step 3: Replace the env block**

```yaml
  env:
    WEBITEL_DBO_ADDRESS: "{{ webitel_pg_dsn_base }}?sslmode={{ webitel_messages_pg_sslmode | default(webitel_pg_sslmode) }}&connect_timeout={{ webitel_messages_pg_connect_timeout | default(webitel_pg_connect_timeout) }}"
    MICRO_REGISTRY_ADDRESS: "{{ webitel_consul_address }}:8500"
    MICRO_BROKER_ADDRESS: "{{ webitel_amqp_url }}?heartbeat={{ webitel_messages_amqp_heartbeat | default(webitel_amqp_heartbeat) }}"
    WEBITEL_BOT_PROXY: "{{ webitel_public_url }}/"
    MICRO_SERVICE_ADDRESS: "{{ '127.0.0.1' if single_node | default(false) else ansible_facts.default_ipv4.address }}:{{ webitel_messages_service_port }}"
    WEBITEL_BOT_ADDRESS: "{{ '127.0.0.1' if single_node | default(false) else ansible_facts.default_ipv4.address }}:{{ webitel_messages_bot_port }}"
    WBTL_LOG_LEVEL: "{{ webitel_messages_log_level | default(webitel_log_level | default('info')) }}"
```

- [ ] **Step 4: Run verify — expect PASS; then lint**

Run: `ansible-playbook /tmp/verify-tunables.yml -i localhost, -e repo=$PWD && yamllint roles/webitel_service/vars/services/messages.yml`
Expected: PASS + 0 порушень.

---

### Task 7: logger spec

**Files:**
- Modify: `roles/webitel_service/vars/services/logger.yml`

- [ ] **Step 1: Add assert to verify playbook**

```yaml
    - name: logger
      block:
        - ansible.builtin.include_vars:
            file: "{{ repo }}/roles/webitel_service/vars/services/logger.yml"
        - ansible.builtin.assert:
            that:
              - webitel_service_spec.env.GRPC_ADDR == '127.0.0.1:10041'
              - "'sslmode=disable' in webitel_service_spec.env.DATASOURCE"
              - "'heartbeat=10' in webitel_service_spec.env.BROKER_ADDRESS"
```

- [ ] **Step 2: Run verify — expect FAIL on logger**

Run: `ansible-playbook /tmp/verify-tunables.yml -i localhost, -e repo=$PWD`
Expected: FAIL на logger assert (GRPC_ADDR ще `127.0.0.1:10011`).

- [ ] **Step 3: Replace the env block**

```yaml
  env:
    CONSUL: "{{ webitel_consul_address }}:8500"
    BROKER_ADDRESS: "{{ webitel_amqp_url }}?heartbeat={{ webitel_logger_amqp_heartbeat | default(webitel_amqp_heartbeat) }}"
    DATASOURCE: "{{ webitel_pg_dsn_base }}?application_name=logger&sslmode={{ webitel_logger_pg_sslmode | default(webitel_pg_sslmode) }}&connect_timeout={{ webitel_logger_pg_connect_timeout | default(webitel_pg_connect_timeout) }}"
    GRPC_ADDR: "{{ '127.0.0.1' if single_node | default(false) else ansible_facts.default_ipv4.address }}:{{ webitel_logger_grpc_port }}"
```

- [ ] **Step 4: Run verify — expect PASS; then lint**

Run: `ansible-playbook /tmp/verify-tunables.yml -i localhost, -e repo=$PWD && yamllint roles/webitel_service/vars/services/logger.yml`
Expected: PASS + 0 порушень.

---

### Task 8: cases spec

**Files:**
- Modify: `roles/webitel_service/vars/services/cases.yml`

- [ ] **Step 1: Add assert to verify playbook**

```yaml
    - name: cases
      block:
        - ansible.builtin.include_vars:
            file: "{{ repo }}/roles/webitel_service/vars/services/cases.yml"
        - ansible.builtin.assert:
            that:
              - webitel_service_spec.env.GRPC_ADDR == '127.0.0.1:10042'
              - "'sslmode=disable' in webitel_service_spec.env.DATA_SOURCE"
              - "'heartbeat=10' in webitel_service_spec.env.MICRO_BROKER_ADDRESS"
```

- [ ] **Step 2: Run verify — expect FAIL on cases**

Run: `ansible-playbook /tmp/verify-tunables.yml -i localhost, -e repo=$PWD`
Expected: FAIL (GRPC_ADDR ще `:22103`).

- [ ] **Step 3: Replace the env block**

```yaml
  env:
    DATA_SOURCE: "{{ webitel_pg_dsn_base }}?application_name=cases&sslmode={{ webitel_cases_pg_sslmode | default(webitel_pg_sslmode) }}&connect_timeout={{ webitel_cases_pg_connect_timeout | default(webitel_pg_connect_timeout) }}"
    CONSUL: "{{ webitel_consul_address }}:8500"
    GRPC_ADDR: "{{ '127.0.0.1' if single_node | default(false) else ansible_facts.default_ipv4.address }}:{{ webitel_cases_grpc_port }}"
    MICRO_BROKER_ADDRESS: "{{ webitel_amqp_url }}?heartbeat={{ webitel_cases_amqp_heartbeat | default(webitel_amqp_heartbeat) }}"
```

- [ ] **Step 4: Run verify — expect PASS; then lint**

Run: `ansible-playbook /tmp/verify-tunables.yml -i localhost, -e repo=$PWD && yamllint roles/webitel_service/vars/services/cases.yml`
Expected: PASS + 0 порушень.

---

### Task 9: media_exporter spec

**Files:**
- Modify: `roles/webitel_service/vars/services/media_exporter.yml`

- [ ] **Step 1: Add assert to verify playbook**

```yaml
    - name: media_exporter
      block:
        - ansible.builtin.include_vars:
            file: "{{ repo }}/roles/webitel_service/vars/services/media_exporter.yml"
        - ansible.builtin.assert:
            that:
              - webitel_service_spec.env.GRPC_ADDR == '127.0.0.1:10043'
              - "'sslmode=disable' in webitel_service_spec.env.DATA_SOURCE"
```

- [ ] **Step 2: Run verify — expect FAIL on media_exporter**

Run: `ansible-playbook /tmp/verify-tunables.yml -i localhost, -e repo=$PWD`
Expected: FAIL (GRPC_ADDR ще `:22500`).

- [ ] **Step 3: Replace the env block**

```yaml
  env:
    CONSUL: "{{ webitel_consul_address }}:8500"
    DATA_SOURCE: "{{ webitel_pg_dsn_base }}?application_name=media_exporter&sslmode={{ webitel_media_exporter_pg_sslmode | default(webitel_pg_sslmode) }}&connect_timeout={{ webitel_media_exporter_pg_connect_timeout | default(webitel_pg_connect_timeout) }}"
    GRPC_ADDR: "{{ '127.0.0.1' if single_node | default(false) else ansible_facts.default_ipv4.address }}:{{ webitel_media_exporter_grpc_port }}"
```

- [ ] **Step 4: Run verify — expect PASS; then lint**

Run: `ansible-playbook /tmp/verify-tunables.yml -i localhost, -e repo=$PWD && yamllint roles/webitel_service/vars/services/media_exporter.yml`
Expected: PASS + 0 порушень.

---

### Task 10: core spec (sslmode + log level)

**Files:**
- Modify: `roles/webitel_service/vars/services/core.yml`

Порти core (api/app) захардкоджені в юнітах (PENDING upstream) — НЕ чіпаємо. Параметризуємо лише `sslmode` у DSN і додаємо `MICRO_LOG_LEVEL`.

- [ ] **Step 1: Add assert to verify playbook**

core.yml містить `webitel_sip_address`/`webitel_cookie_keys` з `lookup('password', …)` та `webitel_cookie_seed` — щоб `include_vars` не впав на undefined, додати `webitel_cookie_seed: testseed` у `vars:` верифікаційного плейбука (Task 1 Step 3), і assert:

```yaml
    - name: core
      block:
        - ansible.builtin.include_vars:
            file: "{{ repo }}/roles/webitel_service/vars/services/core.yml"
        - ansible.builtin.assert:
            that:
              - "'sslmode=disable' in webitel_service_spec.env.WEBITEL_DBO_ADDRESS"
              - webitel_service_spec.env.MICRO_LOG_LEVEL == 'trace'
```

(Додати `webitel_cookie_seed: testseed` до `vars:` плейбука, якщо ще не додано.)

- [ ] **Step 2: Run verify — expect FAIL on core**

Run: `ansible-playbook /tmp/verify-tunables.yml -i localhost, -e repo=$PWD`
Expected: FAIL (MICRO_LOG_LEVEL ще нема; WEBITEL_DBO_ADDRESS має літерал `sslmode=disable`, але MICRO_LOG_LEVEL undefined → assert падає).

- [ ] **Step 3: Edit two env keys**

У `roles/webitel_service/vars/services/core.yml`, у блоці `env:`:

Замінити рядок:
```yaml
    WEBITEL_DBO_ADDRESS: "{{ webitel_pg_dsn_base }}?sslmode=disable"
```
на:
```yaml
    WEBITEL_DBO_ADDRESS: "{{ webitel_pg_dsn_base }}?sslmode={{ webitel_core_pg_sslmode | default(webitel_pg_sslmode) }}"
```

Додати в кінець блоку `env:` новий ключ:
```yaml
    MICRO_LOG_LEVEL: "{{ webitel_core_log_level | default(webitel_log_level | default('trace')) }}"
```

- [ ] **Step 4: Run verify — expect PASS; then lint**

Run: `ansible-playbook /tmp/verify-tunables.yml -i localhost, -e repo=$PWD && yamllint roles/webitel_service/vars/services/core.yml`
Expected: PASS + 0 порушень.

---

### Task 11: nginx — rewrite host AND port for proxied upstreams

**Files:**
- Modify: `roles/nginx/tasks/configure.yml`

Shipped-конфіг (`/etc/nginx/sites-enabled/default`) має ці порти багаторазово: storage `:10023` (×4: POST-upstream + 3 proxy_pass), engine ws `:10022` (×4), messages chat `:10031` (×1). Модуль `replace` глобальний — переписує всі входження. Міняємо: (1) regexp ловить shipped-порт, replace ставить `{{ host }}:{{ knob }}`; (2) прибираємо `when: not single_node` для цих трьох (на single-host порт теж змінюється, host лишається `127.0.0.1` через `nginx_upstream_*`).

> **Обмеження (як і в наявних тасках):** rewrite ефективний на першому прогоні проти свіжо-завантаженого shipped-конфіга (anchor = shipped-порт). Після застосування рядок має новий порт → повторний прогін no-op. Зміна knob-а ПІСЛЯ першого застосування потребує відновлення shipped `default` (видалити файл → `get_url` завантажить наново) або ручної правки. Задокументувати в README.

- [ ] **Step 1: Replace the Storage upstream task**

Замінити таск `- name: Set Webitel Storage upstream address` на:

```yaml
- name: Set Webitel Storage upstream address and port
  ansible.builtin.replace:
    path: /etc/nginx/sites-enabled/default
    regexp: '(proxy_pass http://)127\.0\.0\.1:10023;'
    replace: '\1{{ nginx_upstream_storage }}:{{ webitel_storage_public_port }};'
  notify: restart nginx
```

- [ ] **Step 2: Replace the Storage upload (POST) task**

Замінити таск `- name: Set Webitel Storage upload address` на:

```yaml
- name: Set Webitel Storage upload address and port
  ansible.builtin.replace:
    path: /etc/nginx/sites-enabled/default
    regexp: '(^.*POST.*)(\s"127\.0\.0\.1:10023")(.*$)'
    replace: '\1 "{{ nginx_upstream_storage }}:{{ webitel_storage_public_port }}"\3'
  notify: restart nginx
```

- [ ] **Step 3: Replace the Engine WebSocket task**

Замінити таск `- name: Set Webitel Engine WebSocket upstream address` на:

```yaml
- name: Set Webitel Engine WebSocket upstream address and port
  ansible.builtin.replace:
    path: /etc/nginx/sites-enabled/default
    regexp: '(proxy_pass http://)127\.0\.0\.1:10022;'
    replace: '\1{{ nginx_upstream_engine_ws }}:{{ webitel_engine_websocket_port }};'
  notify: restart nginx
```

- [ ] **Step 4: Replace the Messages task**

Замінити таск `- name: Set Webitel Messages upstream address` на:

```yaml
- name: Set Webitel Messages upstream address and port
  ansible.builtin.replace:
    path: /etc/nginx/sites-enabled/default
    regexp: '(proxy_pass http://)127\.0\.0\.1:10031;'
    replace: '\1{{ nginx_upstream_messages }}:{{ webitel_messages_bot_port }};'
  notify: restart nginx
```

> Таски api (`:8080`/default), opensips (`:5070`), grafana (`:3000`) лишаються **без змін** (host-only, `when: not single_node`).

- [ ] **Step 5: Lint nginx role**

Run: `yamllint roles/nginx/ && ansible-lint roles/nginx`
Expected: 0 порушень.

- [ ] **Step 6: Offline regexp sanity-check against shipped config**

Завантажити shipped-конфіг і прогнати заміни локально, щоб переконатись, що regexp матчиться і дає очікувані порти:

Run:
```bash
curl -fsSL https://git.webitel.com/projects/WEP/repos/nginx/raw/default -o /tmp/wb_default
sed -E 's#(proxy_pass http://)127\.0\.0\.1:10023;#\110.0.0.5:10037;#; s#(proxy_pass http://)127\.0\.0\.1:10022;#\110.0.0.5:10031;#; s#(proxy_pass http://)127\.0\.0\.1:10031;#\110.0.0.5:10040;#' /tmp/wb_default | grep -E ':1003[0-9]|:1004[0-9]'
```
Expected: бачимо `10.0.0.5:10037` (storage ×3), `10.0.0.5:10031` (ws ×4), `10.0.0.5:10040` (messages ×1). Порту `:10022`/`:10023` (proxy_pass) у виводі більше нема. (Це лише перевірка regexp; Ansible-таск робить те саме через `replace`.)

---

### Task 12: Inventory examples + README docs

**Files:**
- Modify: `inventories/multihost.example/group_vars/all/main.yml`
- Modify: `roles/webitel_service/README.md`

- [ ] **Step 1: Add commented knob examples to multihost inventory**

У кінець `inventories/multihost.example/group_vars/all/main.yml` додати (усі закоментовані — це приклади дефолтів):

```yaml

# ──────────────────────────────────────────────────────────────────────────
# Webitel service tunables (опціональні; дефолти показано). Розкоментуйте й
# змініть лише те, що треба. Порти всіх listener-ів — єдиний firewall-блок
# 10030–10043; nginx бере 10031/10037/10040 з тих самих змінних автоматично.
# ──────────────────────────────────────────────────────────────────────────
# Кластерний DSN/AMQP тюнінг (перебивається per-service: webitel_<svc>_pg_sslmode тощо):
# webitel_pg_sslmode: disable
# webitel_pg_connect_timeout: 10
# webitel_amqp_heartbeat: 10
# Кластерний рівень логів (перебивається per-service webitel_<svc>_log_level):
# webitel_log_level: info
#
# Listener-порти (firewall-блок 10030–10043):
# webitel_engine_grpc_port: 10030
# webitel_engine_websocket_port: 10031        # nginx ←
# webitel_call_center_grpc_port: 10032
# webitel_flow_manager_grpc_port: 10033
# webitel_flow_manager_web_port: 10034
# webitel_flow_manager_esl_port: 10035
# webitel_storage_grpc_port: 10036
# webitel_storage_public_port: 10037          # nginx ←
# webitel_storage_internal_port: 10038
# webitel_messages_service_port: 10039
# webitel_messages_bot_port: 10040            # nginx ←
# webitel_logger_grpc_port: 10041
# webitel_cases_grpc_port: 10042
# webitel_media_exporter_grpc_port: 10043
#
# Service-specific:
# webitel_storage_media_directory: /opt/storage/data
# webitel_storage_temp_directory: /var/lib/webitel/storage-temp
# webitel_call_center_omnichannel: 0
```

- [ ] **Step 2: Run yamllint on the inventory file**

Run: `yamllint inventories/multihost.example/group_vars/all/main.yml`
Expected: 0 порушень (усі додані рядки — коментарі).

- [ ] **Step 3: Document tunables in webitel_service README**

У `roles/webitel_service/README.md` додати розділ з повною port-мапою (таблиця «Port block (reference)» з цього плану) + перелік knob-ів (DSN: `webitel_<svc>_pg_sslmode`/`_pg_connect_timeout`/`_amqp_heartbeat`; log: `webitel_<svc>_log_level` + кластерний `webitel_log_level`; service-specific: storage media/temp dir, call_center omnichannel) + примітку про nginx-обмеження з Task 11 (rewrite ефективний на першому прогоні; зміна порту після — через відновлення shipped `default`).

- [ ] **Step 4: Lint README is not needed; verify markdown renders**

Run: `test -s roles/webitel_service/README.md && echo OK`
Expected: OK (файл непорожній).

---

### Task 13: Full validation gate

**Files:** (no edits — verification only)

- [ ] **Step 1: Run full offline render verify (all services)**

Run: `ansible-playbook /tmp/verify-tunables.yml -i localhost, -e repo=$PWD`
Expected: PASS на всіх блоках (engine→core).

- [ ] **Step 2: ansible-lint the three touched roles**

Run: `ansible-lint roles/topology roles/webitel_service roles/nginx`
Expected: 0 порушень.

- [ ] **Step 3: yamllint the whole repo**

Run: `yamllint .`
Expected: 0 порушень.

- [ ] **Step 4: Syntax-check the affected domain playbooks against an example inventory**

Run:
```bash
ansible-playbook playbooks/webitel.yml --syntax-check -i inventories/multihost.example/01-hosts.yml
ansible-playbook playbooks/web.yml --syntax-check -i inventories/multihost.example/01-hosts.yml
```
Expected: обидва — `playbook: …` без помилок.

- [ ] **Step 5: Confirm tags still list cleanly (no spec-load drift)**

Run: `ansible-playbook playbooks/webitel.yml --list-tags -i inventories/multihost.example/01-hosts.yml`
Expected: список тегів виводиться без помилок include_vars.

- [ ] **Step 6: Remove the temp verify playbook**

Run: `rm -f /tmp/verify-tunables.yml /tmp/wb_default`
Expected: прибрано тимчасові файли.

- [ ] **Step 7: Summary for the user**

Підсумувати: які файли змінені, що порти тепер у блоці 10030–10043, що nginx синхронізовано, і що **VM-перевірка** (apply на справжній ноді: `grep -E ':1003|:1004' /etc/nginx/sites-enabled/default`, `ss -ltnp` на сервіс-хостах, перевірка chat-віджета/storage download) лишається фінальним гейтом перед merge. Нагадати, що коміти — за окремим дозволом користувача.

---

## Notes for the executor

- **Не запускати реальний apply** у цьому плані — лише офлайн-рендер + lint + syntax. Функціональна VM-перевірка — окремо (див. Task 13 Step 7).
- **Precedence:** усі port/DSN-факти заморожуються в `topology` (Task 1). Споживачі (`webitel_service`, `nginx`) читають їх напряму. Override користувача — `group_vars/host_vars` тим самим ім'ям; працює, бо RHS у `set_fact` резолвить group_vars ДО заморозки.
- **search_path** у DSN свідомо лишається літералом — це контракт схеми, не tunable.
- **Нові env-ключі** (GRPC_PORT у engine, WEBSOCKET, PUBLIC_ADDRESS/INTERNAL_ADDRESS, ELSE_PORT, ENABLE_OMNICHANNEL, LOG_LVL/MICRO_LOG_LEVEL де їх не було) додаються автоматично — `lineinfile` у `webitel_service/tasks/main.yml` додає рядок, якщо regexp не знайшов ключ.
- **VM-ризики до перевірки:** що бінарі читають `GRPC_PORT` (окремий ключ) в engine/cc/storage/fm; що `ELSE_PORT`/`MICRO_SERVICE_ADDRESS` — listener-и; що storage читає розкоментовані `PUBLIC_ADDRESS`/`INTERNAL_ADDRESS`. Усі звірені з `.env.example` origin/v26.04 на 2026-06-17.
