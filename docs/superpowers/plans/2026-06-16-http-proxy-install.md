# HTTP/HTTPS проксі для install-фази — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Дати змогу вмикати корпоративний HTTP/HTTPS проксі для всього вихідного трафіку install-фази (apt, get_url, apt-transport-s3), не зачіпаючи проекти з прямим доступом.

**Architecture:** Інпути (`http_proxy`/`https_proxy`/`proxy_no_proxy_extra`) задаються в `group_vars/all`. Роль `topology` рахує похідний факт `proxy_env` (dict env-змінних у нижньому й верхньому регістрі + автоматичний `no_proxy`). Кожен компонентний плей отримує `environment: "{{ proxy_env | default({}) }}"`. Немає проксі → `proxy_env == {}` → повний no-op.

**Tech Stack:** Ansible (ansible-core), Jinja2, yamllint, ansible-lint. Верифікація: `--syntax-check`, прогін `playbooks/topology.yml` на `localhost,`.

**Спека:** [docs/superpowers/specs/2026-06-16-http-proxy-install-design.md](../specs/2026-06-16-http-proxy-install-design.md)

---

## Файлова структура

- **Modify:** `roles/topology/tasks/main.yml` — додати дві `set_fact`-секції в кінець (обчислення `_proxy_no_proxy` і `proxy_env`).
- **Modify:** `playbooks/infra.yml`, `playbooks/database.yml`, `playbooks/messaging.yml`, `playbooks/voice.yml`, `playbooks/web.yml`, `playbooks/webitel.yml` — додати `environment:` keyword у кожен install-плей.
- **Modify:** `inventories/multihost.example/group_vars/all/main.yml` — закоментовані приклади інпутів.
- **Modify:** `README.md` — короткий розділ «HTTP proxy (install-time)».
- **Не чіпаємо:** `playbooks/topology.yml` (сам рахує факт — env не потрібен), `playbooks/preflight.yml` (лише assert-и, без егресу, виконується до topology), play «Finish — server key» у `web.yml` (звертається до внутрішнього Webitel URL, покрито `no_proxy`).

---

## Task 1: Факт `proxy_env` у ролі topology

**Files:**
- Modify: `roles/topology/tasks/main.yml` (додати в кінець файлу)
- Test (throwaway): `_proxy_check.yml` у корені репо (видаляється в кроці 6)

- [ ] **Step 1: Створити throwaway-плейбук перевірки**

Створити файл `_proxy_check.yml` у корені репо:

```yaml
---
# THROWAWAY: інтеграційна перевірка факту proxy_env. Видалити після Task 1.
- name: Resolve cluster topology facts
  ansible.builtin.import_playbook: playbooks/topology.yml

- name: Show proxy_env
  hosts: all
  gather_facts: false
  tasks:
    - name: Debug proxy_env
      ansible.builtin.debug:
        var: proxy_env
```

- [ ] **Step 2: Запустити перевірку — переконатись, що факт ще не визначений**

Run:
```bash
ansible-playbook _proxy_check.yml -i 'localhost,' -c local \
  -e webitel_version=26.4 -e nginx_letsencrypt=false
```
Expected: плей проходить, у задачі «Debug proxy_env» виводиться `"proxy_env": "VARIABLE IS NOT DEFINED!"` (факт ще не реалізовано).

- [ ] **Step 3: Реалізувати `set_fact` у topology**

Додати в КІНЕЦЬ `roles/topology/tasks/main.yml` (після секції «Resolve srvinfo URL»):

```yaml
# --- 8. Install-time проксі ---
# Інпути (group_vars): http_proxy / https_proxy / proxy_no_proxy_extra.
# Жоден не заданий → proxy_env == {} → environment у плеях стає no-op.
# no_proxy будуємо автоматично: localhost + .consul + IP усіх хостів кластера
# (щоб apt-кеш/get_url між хостами й локальні запити йшли напряму) + ручні
# додатки. S3-репо свідомо лишається через проксі (зовнішній AWS/MinIO).
- name: Resolve no_proxy list for install-time proxy
  ansible.builtin.set_fact:
    _proxy_no_proxy: >-
      {{ (['localhost', '127.0.0.1', '::1', '.consul']
          + (groups['all'] | default([]) | map('extract', hostvars)
             | selectattr('ansible_default_ipv4.address', 'defined')
             | map(attribute='ansible_default_ipv4.address') | list)
          + (proxy_no_proxy_extra | default([])))
         | unique | join(',') }}

- name: Resolve install-time proxy environment
  ansible.builtin.set_fact:
    proxy_env: >-
      {{ {} if (http_proxy is not defined and https_proxy is not defined) else {
           'http_proxy':  (http_proxy | default(https_proxy)),
           'HTTP_PROXY':  (http_proxy | default(https_proxy)),
           'https_proxy': (https_proxy | default(http_proxy)),
           'HTTPS_PROXY': (https_proxy | default(http_proxy)),
           'no_proxy': _proxy_no_proxy,
           'NO_PROXY': _proxy_no_proxy,
         } }}
```

- [ ] **Step 4: Запустити перевірку без проксі — очікуємо порожній dict**

Run:
```bash
ansible-playbook _proxy_check.yml -i 'localhost,' -c local \
  -e webitel_version=26.4 -e nginx_letsencrypt=false
```
Expected: `"proxy_env": {}`.

- [ ] **Step 5: Запустити перевірку з проксі — очікуємо повний dict**

Run (тільки http_proxy — https має дефолтнутись на нього):
```bash
ansible-playbook _proxy_check.yml -i 'localhost,' -c local \
  -e webitel_version=26.4 -e nginx_letsencrypt=false \
  -e http_proxy=http://proxy.example.com:3128
```
Expected: dict, де `http_proxy`, `HTTP_PROXY`, `https_proxy`, `HTTPS_PROXY` усі = `http://proxy.example.com:3128`, а `no_proxy`/`NO_PROXY` містять `localhost,127.0.0.1,::1,.consul` (плюс локальний IP хоста).

Run (тільки https_proxy — http має дефолтнутись на нього):
```bash
ansible-playbook _proxy_check.yml -i 'localhost,' -c local \
  -e webitel_version=26.4 -e nginx_letsencrypt=false \
  -e https_proxy=http://proxy.example.com:3128
```
Expected: усі чотири proxy-ключі = `http://proxy.example.com:3128`.

- [ ] **Step 6: Прибрати throwaway та прогнати лінтери**

Run:
```bash
rm _proxy_check.yml
yamllint roles/topology/tasks/main.yml
ansible-lint roles/topology/tasks/main.yml
```
Expected: обидва лінтери — без помилок.

- [ ] **Step 7: Commit**

```bash
git add roles/topology/tasks/main.yml
git commit -m "feat(topology): resolve install-time proxy_env fact"
```

---

## Task 2: Підключити `environment` до install-плеїв

Додаємо ОДИН І ТОЙ САМИЙ рядок як play-level keyword одразу після `any_errors_fatal: true` у кожному цільовому плеї:

```yaml
  environment: "{{ proxy_env | default({}) }}"
```

**Files (24 плеї):**
- `playbooks/infra.yml`: «Generate and distribute PKI», «Base system configuration», «Consul servers», «Consul agents», «Nomad servers», «Nomad clients»
- `playbooks/database.yml`: «PostgreSQL standalone (non-HA)», «Patroni cluster (HA)», «HAProxy load balancer for PostgreSQL»
- `playbooks/messaging.yml`: «RabbitMQ messaging»
- `playbooks/voice.yml`: «FreeSWITCH», «RTPEngine», «OpenSIPS»
- `playbooks/web.yml`: «Web tier», «Grafana» (НЕ «Finish — server key»)
- `playbooks/webitel.yml`: «Webitel core (api, app, uac)», «Webitel engine», «Webitel call center», «Webitel flow manager», «Webitel storage», «Webitel messages», «Webitel logger», «Webitel cases», «Webitel media exporter»

- [ ] **Step 1: Відредагувати `playbooks/database.yml`**

Приклад точного результату для першого плею (решта плеїв файлу — аналогічно):

```yaml
- name: PostgreSQL standalone (non-HA)
  hosts: postgres
  become: true
  any_errors_fatal: true
  environment: "{{ proxy_env | default({}) }}"
  roles: [postgres]

- name: Patroni cluster (HA)
  hosts: patroni
  become: true
  any_errors_fatal: true
  environment: "{{ proxy_env | default({}) }}"
  serial: 1
  roles: [patroni]

- name: HAProxy load balancer for PostgreSQL
  hosts: haproxy
  become: true
  any_errors_fatal: true
  environment: "{{ proxy_env | default({}) }}"
  roles: [haproxy]
```

- [ ] **Step 2: Відредагувати решту файлів**

Застосувати ту саму вставку (`  environment: "{{ proxy_env | default({}) }}"` після `any_errors_fatal: true`) у всіх плеях зі списку **Files** вище для `playbooks/infra.yml`, `playbooks/messaging.yml`, `playbooks/voice.yml`, `playbooks/web.yml`, `playbooks/webitel.yml`.

⚠️ У `web.yml` НЕ додавати в плей «Finish — server key» (у нього немає `any_errors_fatal`, він робить лише внутрішній `uri`-запит).

- [ ] **Step 3: Перевірити, що keyword з'явився рівно 24 рази**

Run:
```bash
grep -rc 'environment: "{{ proxy_env' playbooks/ | grep -v ':0'
```
Expected: `infra.yml:6`, `database.yml:3`, `messaging.yml:1`, `voice.yml:3`, `web.yml:2`, `webitel.yml:9` (разом 24).

- [ ] **Step 4: Syntax-check на всіх прикладах інвентарю**

Run:
```bash
for inv in singlehost multihost failover warm-standby-2dc; do
  ansible-playbook --syntax-check -i "inventories/${inv}.example" site.yml || break
done
```
Expected: усі чотири — без помилок.

- [ ] **Step 5: yamllint + ansible-lint**

Run:
```bash
yamllint playbooks/
ansible-lint playbooks/
```
Expected: без помилок.

- [ ] **Step 6: Commit**

```bash
git add playbooks/
git commit -m "feat(playbooks): route install-time egress through proxy_env"
```

---

## Task 3: Документація інпутів

**Files:**
- Modify: `inventories/multihost.example/group_vars/all/main.yml`
- Modify: `README.md`

- [ ] **Step 1: Додати закоментовані інпути в example-інвентар**

У `inventories/multihost.example/group_vars/all/main.yml` додати блок (зручне місце — після блоку S3-репозиторію, бо проксі стосується того ж завантаження пакетів):

```yaml
# --- HTTP proxy (install-фаза) ---
# Розкоментуйте, якщо вихід в інтернет під час провіжинінгу йде через проксі.
# Покриває apt, get_url (GPG-ключі), apt-transport-s3. Не задано — напряму.
# no_proxy рахується автоматично (localhost, .consul, IP усіх хостів кластера).
# http_proxy: "http://proxy.example.com:3128"
# https_proxy: "http://proxy.example.com:3128"   # опційно; дефолт = http_proxy
# proxy_no_proxy_extra: []                          # опційно: ще хости/домени в no_proxy
```

- [ ] **Step 2: Додати розділ у README**

У `README.md` додати розділ (розмістити поряд із описом інвентарю/змінних):

```markdown
### HTTP proxy (install-time)

Для інсталяцій, де вихід в інтернет іде через корпоративний проксі, задайте у
`group_vars/all` інвентарю:

```yaml
http_proxy:  "http://proxy.example.com:3128"
https_proxy: "http://proxy.example.com:3128"   # опційно; дефолт = http_proxy
proxy_no_proxy_extra: []                          # опційно
```

Проксі застосовується лише до install-фази (apt, завантаження GPG-ключів,
apt-transport-s3). `no_proxy` формується автоматично: `localhost`, `.consul`
та IP усіх хостів кластера обходять проксі. Якщо змінні не задані —
провіжинінг іде напряму (для проектів із прямим доступом нічого міняти не треба).
```
```

- [ ] **Step 3: yamllint на зміненому інвентарі**

Run:
```bash
yamllint inventories/multihost.example/group_vars/all/main.yml
```
Expected: без помилок.

- [ ] **Step 4: Commit**

```bash
git add inventories/multihost.example/group_vars/all/main.yml README.md
git commit -m "docs: document install-time http proxy inputs"
```

---

## Фінальна верифікація (вся фіча разом)

- [ ] **Повний лінт + syntax-check (як у CI)**

Run:
```bash
yamllint .
ansible-lint
for inv in singlehost multihost failover warm-standby-2dc; do
  ansible-playbook --syntax-check -i "inventories/${inv}.example" site.yml || break
done
```
Expected: усі кроки — без помилок (повторює `.github/workflows/reviewdog.yml`).
