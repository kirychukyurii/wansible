# webitel_service Role Consolidation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Замінити 9 майже-ідентичних webitel-сервіс-ролей однією data-driven роллю `webitel_service`, керованою per-service vars-файлами + опціональними include-хуками.

**Architecture:** Одна роль `webitel_service` із входом `webitel_service_name`. Дані сервісу (`package/units/env_file/manage_env/env`) — у `roles/webitel_service/vars/services/<name>.yml`. Ядро ролі: install → optional service-hook → env (lineinfile) → systemd enable/start. Особливості — через опціональний `tasks/services/<name>.yml`, не через `when:`. Фазові теги `install`/`configure`; per-service тег навішується на рівні include в плейбуку.

**Tech Stack:** Ansible (production profile), `ansible.builtin.{apt,lineinfile,systemd_service,include_tasks,include_vars}`. Верифікація: `yamllint`, `ansible-lint`, `ansible-playbook --syntax-check`, `--list-tags`.

**Commit policy:** Цей репозиторій має правило «не комітити без явного дозволу». Кроки `Commit` нижче виконуються лише після підтвердження користувача в сесії виконання. Якщо виконання йде через subagent-driven-development — узгодити коміти з користувачем на чекпойнтах.

---

## File Structure

**Створюємо:**
- `roles/webitel_service/defaults/main.yml` — `webitel_service_env_extra: {}`
- `roles/webitel_service/tasks/main.yml` — ядро ролі
- `roles/webitel_service/handlers/main.yml` — generic restart по units
- `roles/webitel_service/README.md` — інтерфейс ролі
- `roles/webitel_service/vars/services/engine.yml`
- `roles/webitel_service/vars/services/logger.yml`
- `roles/webitel_service/vars/services/storage.yml`
- `roles/webitel_service/vars/services/cases.yml`
- `roles/webitel_service/vars/services/call_center.yml`
- `roles/webitel_service/vars/services/flow_manager.yml`
- `roles/webitel_service/vars/services/messages.yml`
- `roles/webitel_service/vars/services/media_exporter.yml`
- `roles/webitel_service/vars/services/core.yml`

**Модифікуємо:**
- `playbooks/webitel.yml` — перевести всі сервіс-плеї на `webitel_service`
- `roles/webitel_common/handlers/main.yml` — прибрати handler «restart webitel core services» (рестарт core тепер у generic-handler)

**Видаляємо (наприкінці):**
- `roles/webitel_core/`, `roles/webitel_engine/`, `roles/webitel_call_center/`, `roles/webitel_flow_manager/`, `roles/webitel_storage/`, `roles/webitel_messages/`, `roles/webitel_logger/`, `roles/webitel_cases/`, `roles/webitel_media_exporter/`

**Не змінюємо:** `playbooks/vars/known_services.yml`, `roles/webitel_common/{tasks,defaults}`, інвентарі.

---

## Task 1: Каркас ролі `webitel_service` (defaults + handler + README)

**Files:**
- Create: `roles/webitel_service/defaults/main.yml`
- Create: `roles/webitel_service/handlers/main.yml`
- Create: `roles/webitel_service/README.md`

- [ ] **Step 1: defaults/main.yml**

```yaml
---
# Per-host override of service env keys. Має пріоритет над spec.env (combine).
# Задається в group_vars/host_vars сервіс-групи.
webitel_service_env_extra: {}
```

- [ ] **Step 2: handlers/main.yml**

```yaml
---
- name: Restart webitel service
  ansible.builtin.systemd_service:
    name: "{{ item }}"
    state: restarted
    daemon_reload: true
  loop: "{{ webitel_service_spec.units | default([webitel_service_spec.package]) }}"
  listen: restart webitel service
```

- [ ] **Step 3: README.md**

````markdown
# webitel_service

Generic data-driven роль для всіх Webitel-мікросервісів. Ставить deb-пакет,
редагує package-shipped env-файл на місці (`lineinfile`, ключ за ключем) і
вмикає systemd-юніти. Замінює окремі ролі `webitel_engine`, `webitel_logger`,
`webitel_storage`, `webitel_cases`, `webitel_call_center`, `webitel_flow_manager`,
`webitel_messages`, `webitel_media_exporter`, `webitel_core`.

## Використання

```yaml
- name: Webitel engine
  hosts: webitel_engine
  become: true
  roles:
    - { role: webitel_service, webitel_service_name: engine, tags: [webitel_engine] }
```

## Вхід

| Змінна | Опис |
|---|---|
| `webitel_service_name` | **Required.** Ім'я сервісу; визначає, який `vars/services/<name>.yml` завантажиться |
| `webitel_service_env_extra` | dict env-ключів, що перекривають `spec.env` (per-host) |

## Каталог сервісу (`vars/services/<name>.yml`)

Один дикт `webitel_service_spec`:

| Ключ | Дефолт | Опис |
|---|---|---|
| `package` | — (required) | назва deb-пакета |
| `units` | `[package]` | список systemd-юнітів |
| `manage_env` | `true` | чи редагувати env-файл |
| `env_file` | `/etc/default/<name>` | шлях до env-файлу пакета |
| `env` | `{}` | dict env-ключів (значення — Jinja, посилаються на спільні group_vars) |

## Теги

- `install` / `configure` — фази (всі сервіси)
- `webitel_<name>` — навішується на рівні include в плейбуку (увесь сервіс)
- Скоуп одного сервісу: `--limit webitel_<name> --tags <phase>`

## Notes

`[VM]` Шляхи env-файлів перевіряти `dpkg -L <package> | grep /etc/default/`.
`lineinfile` без `create: yes` — падає голосно, якщо файл відсутній (навмисно).
````

- [ ] **Step 4: Lint каркасу**

Run: `yamllint roles/webitel_service/ && ansible-lint roles/webitel_service/`
Expected: без помилок (роль ще без tasks/main.yml — ansible-lint може попередити про відсутність; якщо так — продовжити, Task 2 додає tasks).

- [ ] **Step 5: Commit** (після дозволу)

```bash
git add roles/webitel_service/defaults roles/webitel_service/handlers roles/webitel_service/README.md
git commit -m "feat(webitel_service): scaffold generic service role (defaults, handler, README)"
```

---

## Task 2: Ядро ролі `tasks/main.yml`

**Files:**
- Create: `roles/webitel_service/tasks/main.yml`

- [ ] **Step 1: tasks/main.yml**

```yaml
---
- name: Load service spec
  ansible.builtin.include_vars:
    file: "{{ role_path }}/vars/services/{{ webitel_service_name }}.yml"

- name: Install package
  ansible.builtin.apt:
    name: "{{ webitel_service_spec.package }}"
    state: present
    install_recommends: false
  tags: [install]

- name: Service-specific tasks
  ansible.builtin.include_tasks: "{{ role_path }}/tasks/services/{{ webitel_service_name }}.yml"
  when: (role_path ~ '/tasks/services/' ~ webitel_service_name ~ '.yml') is exists
  tags: [install, configure]

- name: Configure env file
  ansible.builtin.lineinfile:
    path: "{{ webitel_service_spec.env_file | default('/etc/default/' ~ webitel_service_name) }}"
    regexp: "^#?\\s*{{ item.key }}="
    line: "{{ item.key }}={{ item.value }}"
    backrefs: false
  loop: "{{ (webitel_service_spec.env | default({}) | combine(webitel_service_env_extra | default({}))) | dict2items }}"
  loop_control:
    label: "{{ item.key }}"
  when: webitel_service_spec.manage_env | default(true)
  notify: restart webitel service
  tags: [configure]

- name: Ensure units enabled and running
  ansible.builtin.systemd_service:
    name: "{{ item }}"
    enabled: true
    state: started
    daemon_reload: true
  loop: "{{ webitel_service_spec.units | default([webitel_service_spec.package]) }}"
  tags: [configure]
```

- [ ] **Step 2: Lint ядра**

Run: `yamllint roles/webitel_service/tasks/main.yml && ansible-lint roles/webitel_service/`
Expected: без помилок.

- [ ] **Step 3: Commit** (після дозволу)

```bash
git add roles/webitel_service/tasks/main.yml
git commit -m "feat(webitel_service): core install/env/systemd logic with service hook"
```

---

## Task 3: Per-service vars-файли (8 сервісів)

**Files:**
- Create: `roles/webitel_service/vars/services/{engine,logger,storage,cases,call_center,flow_manager,messages,media_exporter}.yml`

Кожен файл — один дикт `webitel_service_spec`, перенесений 1:1 з відповідного старого `defaults/main.yml` (значення env незмінні). `GRPC_ADDR`/listen-адреси інлайняться (старий `_*_host_addr` факт розгортається у вираз).

- [ ] **Step 1: engine.yml**

```yaml
---
webitel_service_spec:
  package: webitel-engine
  units: [webitel-engine]
  env_file: /etc/default/engine
  env:
    CONSUL: "{{ webitel_consul_address }}:8500"
    AMQP: "{{ webitel_amqp_url }}?heartbeat=10"
    DATA_SOURCE: "{{ webitel_pg_dsn_base }}?fallback_application_name=engine&sslmode=disable&connect_timeout=10&search_path=call_center"
    SQL_DATA_SOURCE_REPLICAS: "{{ webitel_pg_dsn_replicas }}?fallback_application_name=engine&sslmode=disable&connect_timeout=10&search_path=call_center"
    OPEN_SIP_ADDR: "{{ webitel_opensips_host }}"
    SIP_PROXY_ADDR: "sip:{{ webitel_opensips_host }}"
    GRPC_ADDR: "{{ '127.0.0.1' if single_node | default(false) else ansible_facts.default_ipv4.address }}"
    PUBLIC_HOST: "{{ webitel_public_url }}"
```

- [ ] **Step 2: logger.yml**

```yaml
---
webitel_service_spec:
  package: webitel-logger
  units: [webitel-logger]
  env_file: /etc/default/webitel-logger
  env:
    CONSUL: "{{ webitel_consul_address }}:8500"
    BROKER_ADDRESS: "{{ webitel_amqp_url }}?heartbeat=10"
    DATASOURCE: "{{ webitel_pg_dsn_base }}?application_name=logger&sslmode=disable&connect_timeout=10"
    GRPC_ADDR: "{{ '127.0.0.1' if single_node | default(false) else ansible_facts.default_ipv4.address }}:10011"
```

- [ ] **Step 3: storage.yml**

```yaml
---
webitel_service_spec:
  package: webitel-storage
  units: [webitel-storage]
  env_file: /etc/default/storage
  env:
    CONSUL: "{{ webitel_consul_address }}:8500"
    MESSAGE_BROKER_URL: "{{ webitel_amqp_url }}?heartbeat=10"
    DATA_SOURCE: "{{ webitel_pg_dsn_base }}?application_name=storage&sslmode=disable&connect_timeout=10"
    SQL_DATA_SOURCE_REPLICAS: "{{ webitel_pg_dsn_replicas }}?application_name=storage&sslmode=disable&connect_timeout=10"
    GRPC_ADDR: "{{ '127.0.0.1' if single_node | default(false) else ansible_facts.default_ipv4.address }}"
    PUBLIC_HOST: "{{ webitel_public_url }}"
```

- [ ] **Step 4: cases.yml**

```yaml
---
webitel_service_spec:
  package: webitel-cases
  units: [webitel-cases]
  env_file: /etc/default/webitel-cases
  env:
    DATA_SOURCE: "{{ webitel_pg_dsn_base }}?application_name=cases&sslmode=disable&connect_timeout=10"
    CONSUL: "{{ webitel_consul_address }}:8500"
    GRPC_ADDR: "{{ '127.0.0.1' if single_node | default(false) else ansible_facts.default_ipv4.address }}:22103"
    MICRO_BROKER_ADDRESS: "{{ webitel_amqp_url }}?heartbeat=10"
```

- [ ] **Step 5: call_center.yml**

```yaml
---
webitel_service_spec:
  package: webitel-call-center
  units: [webitel-call-center]
  env_file: /etc/default/call_center
  env:
    CONSUL: "{{ webitel_consul_address }}:8500"
    AMQP: "{{ webitel_amqp_url }}?heartbeat=10"
    DATA_SOURCE: "{{ webitel_pg_dsn_base }}?application_name=call_center&sslmode=disable&connect_timeout=10&search_path=call_center"
    SQL_DATA_SOURCE_REPLICAS: "{{ webitel_pg_dsn_replicas }}?application_name=call_center&sslmode=disable&connect_timeout=10&search_path=call_center"
    GRPC_ADDR: "{{ '127.0.0.1' if single_node | default(false) else ansible_facts.default_ipv4.address }}"
```

- [ ] **Step 6: flow_manager.yml**

```yaml
---
webitel_service_spec:
  package: webitel-flow-manager
  units: [webitel-flow-manager]
  env_file: /etc/default/flow_manager
  env:
    CONSUL: "{{ webitel_consul_address }}:8500"
    AMQP: "{{ webitel_amqp_url }}?heartbeat=10"
    DATA_SOURCE: "{{ webitel_pg_dsn_base }}?sslmode=disable&connect_timeout=10"
    SQL_DATA_SOURCE_REPLICAS: "{{ webitel_pg_dsn_replicas }}?sslmode=disable&connect_timeout=10"
    GRPC_ADDR: "{{ '127.0.0.1' if single_node | default(false) else ansible_facts.default_ipv4.address }}"
    WEB_ADDR: "{{ '127.0.0.1' if single_node | default(false) else ansible_facts.default_ipv4.address }}:5689"
```

- [ ] **Step 7: messages.yml** (multi-unit, single env file)

```yaml
---
webitel_service_spec:
  package: webitel-messages
  units: [webitel-messages-srv, webitel-messages-bot]
  env_file: /etc/default/webitel-messages
  env:
    WEBITEL_DBO_ADDRESS: "{{ webitel_pg_dsn_base }}?sslmode=disable&connect_timeout=10"
    MICRO_REGISTRY_ADDRESS: "{{ webitel_consul_address }}:8500"
    MICRO_BROKER_ADDRESS: "{{ webitel_amqp_url }}?heartbeat=10"
    WEBITEL_BOT_PROXY: "{{ webitel_public_url }}/"
    MICRO_SERVICE_ADDRESS: "{{ '127.0.0.1' if single_node | default(false) else ansible_facts.default_ipv4.address }}:0"
    WEBITEL_BOT_ADDRESS: "{{ '127.0.0.1' if single_node | default(false) else ansible_facts.default_ipv4.address }}:10030"
```

- [ ] **Step 8: media_exporter.yml**

```yaml
---
webitel_service_spec:
  package: webitel-media-exporter
  units: [webitel-media-exporter]
  env_file: /etc/default/media-exporter
  env:
    CONSUL: "{{ webitel_consul_address }}:8500"
    DATA_SOURCE: "{{ webitel_pg_dsn_base }}?application_name=media_exporter&sslmode=disable&connect_timeout=10"
    GRPC_ADDR: "{{ '127.0.0.1' if single_node | default(false) else ansible_facts.default_ipv4.address }}:22500"
```

- [ ] **Step 9: Lint vars-файлів**

Run: `yamllint roles/webitel_service/vars/`
Expected: без помилок.

- [ ] **Step 10: Commit** (після дозволу)

```bash
git add roles/webitel_service/vars/services/
git commit -m "feat(webitel_service): add per-service catalog (8 standard services)"
```

---

## Task 4: core.yml (особливий сервіс через дані)

**Files:**
- Create: `roles/webitel_service/vars/services/core.yml`

`webitel_core` ставив 3 юніти і **не** редагував env (`manage_env: false`).

- [ ] **Step 1: core.yml**

```yaml
---
webitel_service_spec:
  package: webitel-core
  units: [webitel-api, webitel-app, webitel-uac]
  manage_env: false
```

- [ ] **Step 2: Lint**

Run: `yamllint roles/webitel_service/vars/services/core.yml`
Expected: без помилок.

- [ ] **Step 3: Commit** (після дозволу)

```bash
git add roles/webitel_service/vars/services/core.yml
git commit -m "feat(webitel_service): fold webitel-core into catalog (3 units, manage_env=false)"
```

---

## Task 5: Перевести `playbooks/webitel.yml` на `webitel_service`

**Files:**
- Modify: `playbooks/webitel.yml`

- [ ] **Step 1: Замінити сервіс-плеї**

Лишити перший плей `Webitel common configuration` (роль `webitel_common`) без змін. Решту плеїв замінити на виклики `webitel_service`. Повний новий вміст після першого плею:

```yaml
- name: Webitel core (api, app, uac)
  hosts: webitel_core
  become: true
  any_errors_fatal: true
  roles:
    - { role: webitel_service, webitel_service_name: core, tags: [webitel_core] }

- name: Webitel engine
  hosts: webitel_engine
  become: true
  any_errors_fatal: true
  roles:
    - { role: webitel_service, webitel_service_name: engine, tags: [webitel_engine] }

- name: Webitel call center
  hosts: webitel_call_center
  become: true
  any_errors_fatal: true
  roles:
    - { role: webitel_service, webitel_service_name: call_center, tags: [webitel_call_center] }

- name: Webitel flow manager
  hosts: webitel_flow_manager
  become: true
  any_errors_fatal: true
  roles:
    - { role: webitel_service, webitel_service_name: flow_manager, tags: [webitel_flow_manager] }

- name: Webitel storage
  hosts: webitel_storage
  become: true
  any_errors_fatal: true
  roles:
    - { role: webitel_service, webitel_service_name: storage, tags: [webitel_storage] }

- name: Webitel messages
  hosts: webitel_messages
  become: true
  any_errors_fatal: true
  roles:
    - { role: webitel_service, webitel_service_name: messages, tags: [webitel_messages] }

- name: Webitel logger
  hosts: webitel_logger
  become: true
  any_errors_fatal: true
  roles:
    - { role: webitel_service, webitel_service_name: logger, tags: [webitel_logger] }

- name: Webitel cases
  hosts: webitel_cases
  become: true
  any_errors_fatal: true
  roles:
    - { role: webitel_service, webitel_service_name: cases, tags: [webitel_cases] }

- name: Webitel media exporter
  hosts: webitel_media_exporter
  become: true
  any_errors_fatal: true
  roles:
    - { role: webitel_service, webitel_service_name: media_exporter, tags: [webitel_media_exporter] }
```

- [ ] **Step 2: Syntax + lint**

Run: `ansible-playbook playbooks/webitel.yml --syntax-check && ansible-lint playbooks/webitel.yml`
Expected: без помилок.

- [ ] **Step 3: Commit** (після дозволу)

```bash
git add playbooks/webitel.yml
git commit -m "refactor(webitel): drive all service plays through webitel_service role"
```

---

## Task 6: ~~Прибрати делегований рестарт core з `webitel_common`~~ — СКАСОВАНО

**Рішення при реалізації: handler ЛИШАЄТЬСЯ, нічого не змінюємо.**

Перевірка показала, що `webitel_common/tasks/configure.yml` сам робить
`notify: restart webitel core services` — він рендерить спільний
`/etc/default/webitel`, який споживають core-юніти. Цей зв'язок не залежить від
консолідації ролей. `webitel_service` для core має `manage_env: false`, конфлікту
немає. Handler і notify лишаються недоторканими. Завдання видалено зі скоупу.

<details><summary>початковий (хибний) план</summary>

Рестарт core-юнітів тепер робить generic-handler `webitel_service`. Handler «restart webitel core services» у `webitel_common` більше не потрібен — за умови, що на нього ніхто не `notify`-ить поза core-роллю.

- [ ] **Step 1: Перевірити, чи handler ще використовується**

Run: `grep -rn "restart webitel core services" roles/ playbooks/`
Expected: посилання лишилися тільки в `roles/webitel_common/handlers/main.yml` (визначення). Якщо є `notify:` деінде — НЕ видаляти; зупинитись і повідомити користувача.

- [ ] **Step 2: Видалити блок handler-а**

Видалити з `roles/webitel_common/handlers/main.yml` блок:

```yaml
- name: Restart webitel core services
  ansible.builtin.systemd_service:
    name: "{{ item }}"
    state: restarted
    daemon_reload: true
  loop: [webitel-api, webitel-app, webitel-uac]
  when: inventory_hostname in groups['webitel_core'] | default([])
  listen: restart webitel core services
```

Якщо файл стає порожнім (лише `---`), лишити його з `---` і коментарем `# No common handlers.`

- [ ] **Step 3: Lint**

Run: `yamllint roles/webitel_common/handlers/main.yml && ansible-lint roles/webitel_common/`
Expected: без помилок.

- [ ] **Step 4: Commit** (після дозволу)

```bash
git add roles/webitel_common/handlers/main.yml
git commit -m "refactor(webitel_common): drop delegated core restart (handled by webitel_service)"
```

</details>

---

## Task 7: Видалити старі сервіс-ролі

**Files:**
- Delete: `roles/webitel_core/`, `roles/webitel_engine/`, `roles/webitel_call_center/`, `roles/webitel_flow_manager/`, `roles/webitel_storage/`, `roles/webitel_messages/`, `roles/webitel_logger/`, `roles/webitel_cases/`, `roles/webitel_media_exporter/`

- [ ] **Step 1: Перевірити, що на старі ролі ніхто не посилається**

Run:
```bash
grep -rnE "webitel_(core|engine|call_center|flow_manager|storage|messages|logger|cases|media_exporter)" playbooks/ roles/ | grep -vE "known_services\.yml|webitel_service|hosts:|name:|webitel_common"
```
Expected: жодного посилання на старі ролі як на `role:`/`include_role:`. (`known_services.yml` і `hosts:`-групи — це імена груп, не ролей, лишаються.)

- [ ] **Step 2: Видалити папки**

```bash
git rm -r roles/webitel_core roles/webitel_engine roles/webitel_call_center \
  roles/webitel_flow_manager roles/webitel_storage roles/webitel_messages \
  roles/webitel_logger roles/webitel_cases roles/webitel_media_exporter
```

- [ ] **Step 3: Повна верифікація репо**

Run:
```bash
yamllint . && \
ansible-lint && \
ansible-playbook playbooks/webitel.yml --syntax-check && \
ansible-playbook playbooks/webitel.yml --list-tags
```
Expected: lint зелений; `--list-tags` показує `install`, `configure` і `webitel_<name>` для кожного сервісу; жодних посилань на видалені ролі.

- [ ] **Step 4: Commit** (після дозволу)

```bash
git add -A
git commit -m "refactor(webitel): remove per-service roles superseded by webitel_service"
```

---

## Task 8: Функціональний прогін (за користувачем)

**Files:** —

Прогін в OrbStack — за користувачем (середовище тестове, env-файли пакетів редагуються на місці).

- [ ] **Step 1: Single-node прогін**

Run: `ansible-playbook playbooks/webitel.yml` (проти singlehost-інвентаря)
Expected: усі сервіси install+configure ідемпотентно; повторний прогін — `changed=0` на env-кроках; юніти `active`.

- [ ] **Step 2: Точкова перевірка env**

На цільовому хості: `cat /etc/default/engine` — переконатись, що ключі збігаються зі старою роллю (CONSUL/AMQP/DATA_SOURCE/...).

- [ ] **Step 3: Перевірка тега-скоупінгу**

Run: `ansible-playbook playbooks/webitel.yml --limit webitel_engine --tags configure --check`
Expected: зачіпає лише engine-хост, лише configure-кроки.

---

## Self-Review Notes

- **Spec coverage:** одна роль (Task 1–2) ✓; per-service vars з discoverability (Task 3–4) ✓; include-хук запобіжник (Task 2, step include_tasks) ✓; core через дані + generic restart (Task 4, 6) ✓; фазові теги + per-service тег (Task 2, 5) ✓; видалення 9 ролей, `known_services`/`webitel_common` tasks без змін (Task 7) ✓; override через `webitel_service_env_extra` (Task 1–2) ✓.
- **Type consistency:** `webitel_service_spec` (.package/.units/.env_file/.manage_env/.env) і `webitel_service_env_extra` вживаються однаково в tasks, handler, README, vars-файлах. Тег `restart webitel service` (notify ↔ listen) збігається.
- **Hook:** `tasks/services/<name>.yml` наразі не створюється для жодного сервісу (core вирішено через `manage_env: false`, не через хук) — це навмисно; хук готовий до майбутніх особливостей.
