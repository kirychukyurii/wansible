# nginx TLS modes (Блок 3.1) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Дати nginx три взаємовиключні режими TLS (`letsencrypt | provided | self_signed`) замість єдиного LE-шляху, закривши поточну дірку, коли `nginx_letsencrypt: false` лишає HTTPS без керованого сертифіката.

**Architecture:** Нова змінна `nginx_tls_mode` з back-compat дефолтом від `nginx_letsencrypt`. Режим `letsencrypt` лишається в `playbooks/web.yml` через роль `certbot` (тільки гейт переписуємо). Режими `provided`/`self_signed` обробляє нова `roles/nginx/tasks/tls.yml`: кладе серт у канонічний шлях (`/etc/nginx/ssl/<site>.{crt,key}`), патчить `ssl_certificate`/`ssl_certificate_key`/`server_name` у завантаженому `default`-сайті (той самий `replace`-ідіом, що вже в `configure.yml`), валідує `nginx -t`. self_signed генерується через `community.crypto` (дзеркало pki-ролі, але `provider=selfsigned`).

**Tech Stack:** Ansible (ansible-core), `community.crypto`, Jinja2, yamllint, ansible-lint. Верифікація: `ansible -m debug` для резолву змінної, `--syntax-check` на прикладах інвентарю, лінтери як у CI.

**Спека:** [docs/superpowers/specs/2026-06-20-nginx-tls-modes-design.md](../specs/2026-06-20-nginx-tls-modes-design.md)

---

## Файлова структура

- **Modify:** `roles/nginx/defaults/main.yml` — додати модель змінних TLS (`nginx_tls_mode`, шляхи, `provided`-джерела, self_signed-параметри).
- **Create:** `roles/nginx/tasks/tls.yml` — диспатч за `nginx_tls_mode` для `provided`/`self_signed` (генерація/копіювання серта, патч конфіга, `nginx -t`).
- **Modify:** `roles/nginx/tasks/main.yml` — інклуд `tls.yml` після `configure.yml`.
- **Modify:** `playbooks/web.yml` — гейт certbot із `nginx_letsencrypt` на `nginx_tls_mode == 'letsencrypt'`.
- **Modify:** `playbooks/preflight.yml` — assert набору `nginx_tls_mode` + вимоги `provided`/`self_signed`; переписати існуючий LE-assert на новий гейт.
- **Modify:** `roles/nginx/README.md` — розділ про режими TLS.
- **Modify:** `inventories/multihost.example/group_vars/all/main.yml` — закоментовані приклади `nginx_tls_mode`.
- **Modify:** `inventories/production/group_vars/all/main.yml` — приклад `provided` для kcsd.kz (закоментований).
- **Не чіпаємо:** `roles/certbot/` (лишається тільки-LE), `roles/nginx/tasks/configure.yml`, `roles/nginx/handlers/main.yml` (handler `restart nginx` уже є).

**Канонічні шляхи й змінні (єдине джерело — defaults):**
- `nginx_tls_dir: /etc/nginx/ssl`
- `nginx_tls_cert_path: {{ nginx_tls_dir }}/{{ nginx_site_name }}.crt`
- `nginx_tls_key_path: {{ nginx_tls_dir }}/{{ nginx_site_name }}.key`

---

## Task 1: Модель змінних TLS у defaults

**Files:**
- Modify: `roles/nginx/defaults/main.yml` (додати в кінець файлу)

- [ ] **Step 1: Перевірити back-compat вираз режиму ДО реалізації**

Run:
```bash
ansible localhost -m debug -a "msg={{ 'letsencrypt' if nginx_letsencrypt | default(false) | bool else 'self_signed' }}"
ansible localhost -m debug -a "msg={{ 'letsencrypt' if nginx_letsencrypt | default(false) | bool else 'self_signed' }}" -e nginx_letsencrypt=true
```
Expected: перший — `"msg": "self_signed"`; другий — `"msg": "letsencrypt"`. (Підтверджує логіку дефолту, який зараз закладаємо.)

- [ ] **Step 2: Додати блок TLS у `roles/nginx/defaults/main.yml`**

Додати в КІНЕЦЬ файлу:

```yaml

# --- TLS ---
# Режим TLS для публічного nginx. Взаємовиключні значення:
#   letsencrypt  — справжній LE-серт через роль certbot (playbooks/web.yml).
#   provided     — адмін кладе власний серт (корпоративний CA / wildcard).
#   self_signed  — роль генерує self-signed під nginx_site_name (фолбек, browser warning).
# Дефолт похідний від back-compat прапора nginx_letsencrypt: усі інвентарі на
# letsencrypt:false автоматично отримують self_signed → HTTPS працює з коробки.
nginx_tls_mode: "{{ 'letsencrypt' if nginx_letsencrypt | default(false) | bool else 'self_signed' }}"

# Канонічне місце керованого серта (для provided/self_signed; letsencrypt має свої шляхи).
nginx_tls_dir: /etc/nginx/ssl
nginx_tls_cert_path: "{{ nginx_tls_dir }}/{{ nginx_site_name }}.crt"
nginx_tls_key_path: "{{ nginx_tls_dir }}/{{ nginx_site_name }}.key"

# provided: шляхи НА КОНТРОЛЕРІ до серта/ключа, які роль скопіює в канонічне місце.
# Якщо файли вже лежать на таргеті за канонічним шляхом — лишіть порожніми (copy пропуститься).
nginx_tls_cert: ""
nginx_tls_key: ""

# self_signed: ключ і валідність. RSA-2048 — максимальна сумісність браузерів.
nginx_tls_self_signed_key_type: RSA
nginx_tls_self_signed_key_size: 2048
nginx_tls_self_signed_days: 825
```

- [ ] **Step 3: yamllint**

Run:
```bash
yamllint roles/nginx/defaults/main.yml
```
Expected: без помилок.

- [ ] **Step 4: Commit**

```bash
git add roles/nginx/defaults/main.yml
git commit -m "feat(nginx): add nginx_tls_mode variable model"
```

---

## Task 2: Таск-файл `tls.yml` (provided / self_signed)

**Files:**
- Create: `roles/nginx/tasks/tls.yml`
- Modify: `roles/nginx/tasks/main.yml`

- [ ] **Step 1: Створити `roles/nginx/tasks/tls.yml`**

```yaml
---
# Керування публічним TLS-сертом nginx для режимів provided/self_signed.
# Режим letsencrypt сюди не заходить — ним керує роль certbot із playbooks/web.yml.

- name: Ensure TLS directory exists
  ansible.builtin.file:
    path: "{{ nginx_tls_dir }}"
    state: directory
    owner: root
    group: root
    mode: "0755"
  when: nginx_tls_mode in ['provided', 'self_signed']

# --- self_signed: генеруємо серт на таргеті (дзеркало pki-ролі, provider=selfsigned) ---
- name: Generate self-signed private key
  community.crypto.openssl_privatekey:
    path: "{{ nginx_tls_key_path }}"
    type: "{{ nginx_tls_self_signed_key_type }}"
    size: "{{ nginx_tls_self_signed_key_size }}"
    mode: "0640"
  when: nginx_tls_mode == 'self_signed'

- name: Generate self-signed CSR
  community.crypto.openssl_csr:
    path: "{{ nginx_tls_dir }}/{{ nginx_site_name }}.csr"
    privatekey_path: "{{ nginx_tls_key_path }}"
    common_name: "{{ nginx_site_name }}"
    subject_alt_name:
      - "DNS:{{ nginx_site_name }}"
    mode: "0644"
  when: nginx_tls_mode == 'self_signed'

- name: Create self-signed certificate
  community.crypto.x509_certificate:
    path: "{{ nginx_tls_cert_path }}"
    privatekey_path: "{{ nginx_tls_key_path }}"
    csr_path: "{{ nginx_tls_dir }}/{{ nginx_site_name }}.csr"
    provider: selfsigned
    selfsigned_not_after: "+{{ nginx_tls_self_signed_days }}d"
    mode: "0644"
  when: nginx_tls_mode == 'self_signed'
  notify: restart nginx

# --- provided: копіюємо серт/ключ із контролера (якщо джерела задані) ---
- name: Copy provided certificate
  ansible.builtin.copy:
    src: "{{ nginx_tls_cert }}"
    dest: "{{ nginx_tls_cert_path }}"
    owner: root
    group: root
    mode: "0644"
  when:
    - nginx_tls_mode == 'provided'
    - nginx_tls_cert | length > 0
  notify: restart nginx

- name: Copy provided private key
  ansible.builtin.copy:
    src: "{{ nginx_tls_key }}"
    dest: "{{ nginx_tls_key_path }}"
    owner: root
    group: root
    mode: "0640"
  when:
    - nginx_tls_mode == 'provided'
    - nginx_tls_key | length > 0
  notify: restart nginx

# --- спільне: націлити nginx на керований серт і виставити server_name ---
# (для letsencrypt це робить certbot сам, тож пропускаємо)
- name: Point nginx at managed certificate
  ansible.builtin.replace:
    path: /etc/nginx/sites-enabled/default
    regexp: '(^\s*ssl_certificate\s+)\S+;'
    replace: '\g<1>{{ nginx_tls_cert_path }};'
  when: nginx_tls_mode in ['provided', 'self_signed']
  notify: restart nginx

- name: Point nginx at managed certificate key
  ansible.builtin.replace:
    path: /etc/nginx/sites-enabled/default
    regexp: '(^\s*ssl_certificate_key\s+)\S+;'
    replace: '\g<1>{{ nginx_tls_key_path }};'
  when: nginx_tls_mode in ['provided', 'self_signed']
  notify: restart nginx

- name: Set server_name (non-letsencrypt modes)
  ansible.builtin.replace:
    path: /etc/nginx/sites-enabled/default
    regexp: '(server_name )[^;]*(;)'
    replace: '\g<1>{{ nginx_site_name }}\g<2>'
  when: nginx_tls_mode in ['provided', 'self_signed']
  notify: restart nginx

- name: Validate nginx configuration
  ansible.builtin.command:
    cmd: nginx -t
  changed_when: false
  when: nginx_tls_mode in ['provided', 'self_signed']
```

⚠️ **Припущення:** завантажений `default`-сайт Webitel містить активні директиви
`ssl_certificate` та `ssl_certificate_key` (vhost на 443) — `replace` редагує їхнє
значення. Крок «Validate nginx configuration» (`nginx -t`) спіймає невідповідність
гучно під час прогону. Якщо при першому реальному прогоні `nginx -t` впаде через
відсутність директиви — додати їх через `blockinfile` у 443-server-блок (поза скоупом
цього плану, окремий фікс).

- [ ] **Step 2: Підключити `tls.yml` у `roles/nginx/tasks/main.yml`**

Додати в кінець `roles/nginx/tasks/main.yml` (після блоку `configure`):

```yaml

- name: Include nginx TLS tasks
  ansible.builtin.include_tasks:
    file: tls.yml
    apply:
      tags: [nginx_tls]
  tags: [nginx_tls]
```

- [ ] **Step 3: yamllint + ansible-lint**

Run:
```bash
yamllint roles/nginx/tasks/tls.yml roles/nginx/tasks/main.yml
ansible-lint roles/nginx/tasks/tls.yml roles/nginx/tasks/main.yml
```
Expected: без помилок.

- [ ] **Step 4: Syntax-check на всіх прикладах інвентарю**

Run:
```bash
for inv in singlehost multihost failover warm-standby-2dc; do
  ansible-playbook --syntax-check -i "inventories/${inv}.example" site.yml || break
done
```
Expected: усі чотири — без помилок.

- [ ] **Step 5: Commit**

```bash
git add roles/nginx/tasks/tls.yml roles/nginx/tasks/main.yml
git commit -m "feat(nginx): handle provided/self_signed TLS modes"
```

---

## Task 3: Гейт certbot + preflight

**Files:**
- Modify: `playbooks/web.yml:14-17`
- Modify: `playbooks/preflight.yml:68-77`

- [ ] **Step 1: Переписати гейт certbot у `playbooks/web.yml`**

Замінити блок (рядки 14-17):

```yaml
    - name: Web | Include certbot
      ansible.builtin.include_role:
        name: certbot
      when: nginx_letsencrypt | default(false) | bool
```

на:

```yaml
    - name: Web | Include certbot
      ansible.builtin.include_role:
        name: certbot
      when: nginx_tls_mode | default('self_signed') == 'letsencrypt'
```

- [ ] **Step 2: Переписати LE-assert і додати нові у `playbooks/preflight.yml`**

Замінити блок «Preflight | Require LetsEncrypt settings when enabled» (рядки 68-77) на:

```yaml
    - name: Preflight | nginx_tls_mode must be a known value
      ansible.builtin.assert:
        that:
          - nginx_tls_mode | default('self_signed') in ['letsencrypt', 'provided', 'self_signed']
        fail_msg: "nginx_tls_mode must be one of: letsencrypt, provided, self_signed"
        quiet: true
      when: "'nginx' in (services | default([]))"

    - name: Preflight | Require nginx_site_name for nginx TLS
      ansible.builtin.assert:
        that:
          - nginx_site_name | default('') | length > 0
        fail_msg: "nginx TLS requires nginx_site_name (CN / server_name)"
        quiet: true
      when: "'nginx' in (services | default([]))"

    - name: Preflight | Require mail address for letsencrypt
      ansible.builtin.assert:
        that:
          - nginx_mail_address | default('') | length > 0
        fail_msg: "nginx_tls_mode=letsencrypt requires nginx_mail_address"
        quiet: true
      when:
        - "'nginx' in (services | default([]))"
        - nginx_tls_mode | default('self_signed') == 'letsencrypt'

    - name: Preflight | Require cert+key sources for provided TLS
      ansible.builtin.assert:
        that:
          - nginx_tls_cert | default('') | length > 0
          - nginx_tls_key | default('') | length > 0
        fail_msg: >-
          nginx_tls_mode=provided requires nginx_tls_cert and nginx_tls_key
          (controller-side paths to certificate and private key)
        quiet: true
      when:
        - "'nginx' in (services | default([]))"
        - nginx_tls_mode | default('self_signed') == 'provided'
```

- [ ] **Step 3: yamllint + ansible-lint**

Run:
```bash
yamllint playbooks/web.yml playbooks/preflight.yml
ansible-lint playbooks/web.yml playbooks/preflight.yml
```
Expected: без помилок.

- [ ] **Step 4: Syntax-check на всіх прикладах інвентарю**

Run:
```bash
for inv in singlehost multihost failover warm-standby-2dc; do
  ansible-playbook --syntax-check -i "inventories/${inv}.example" site.yml || break
done
```
Expected: усі чотири — без помилок.

- [ ] **Step 5: Commit**

```bash
git add playbooks/web.yml playbooks/preflight.yml
git commit -m "feat(playbooks): gate certbot and preflight on nginx_tls_mode"
```

---

## Task 4: Документація і приклади інвентарю

**Files:**
- Modify: `roles/nginx/README.md`
- Modify: `inventories/multihost.example/group_vars/all/main.yml`
- Modify: `inventories/production/group_vars/all/main.yml`

- [ ] **Step 1: Додати розділ TLS у `roles/nginx/README.md`**

Додати розділ (після опису certbot-інтеграції):

```markdown
## TLS modes

`nginx_tls_mode` selects how the public certificate is provisioned (mutually exclusive):

| Mode | Behaviour |
|------|-----------|
| `letsencrypt` | Real Let's Encrypt cert via the `certbot` role (`playbooks/web.yml`). Public domains only. |
| `provided` | Operator supplies `nginx_tls_cert` / `nginx_tls_key` (controller-side paths); the role copies them to `/etc/nginx/ssl/<site>.{crt,key}` and points nginx at them. For corporate-CA / wildcard certs. |
| `self_signed` | The role generates a self-signed cert for `nginx_site_name`. Default fallback; browsers show a warning. |

The default is derived from the legacy `nginx_letsencrypt` flag: `true` → `letsencrypt`,
`false` → `self_signed`. Set `nginx_tls_mode` explicitly to override.
```

- [ ] **Step 2: Додати закоментовані приклади в `inventories/multihost.example/group_vars/all/main.yml`**

Поряд із рядками `nginx_letsencrypt` / `nginx_site_name` додати:

```yaml
# nginx_tls_mode: self_signed        # letsencrypt | provided | self_signed
#                                       (дефолт: letsencrypt якщо nginx_letsencrypt:true, інакше self_signed)
# nginx_tls_cert: /path/on/controller/site.crt   # лише для provided
# nginx_tls_key:  /path/on/controller/site.key   # лише для provided
```

- [ ] **Step 3: Додати приклад provided для kcsd.kz у `inventories/production/group_vars/all/main.yml`**

Поряд із рядком `nginx_letsencrypt: false` додати:

```yaml
# kcsd.kz без публічного LE — серт із корпоративного CA:
# nginx_tls_mode: provided
# nginx_tls_cert: /path/on/controller/contact.kcsd.kz.crt
# nginx_tls_key:  /path/on/controller/contact.kcsd.kz.key
```

- [ ] **Step 4: yamllint**

Run:
```bash
yamllint inventories/multihost.example/group_vars/all/main.yml inventories/production/group_vars/all/main.yml roles/nginx/README.md
```
Expected: без помилок (README — markdown, yamllint його ігнорує; перевірка лише валідації YAML-файлів).

- [ ] **Step 5: Commit**

```bash
git add roles/nginx/README.md inventories/multihost.example/group_vars/all/main.yml inventories/production/group_vars/all/main.yml
git commit -m "docs(nginx): document TLS modes and inventory examples"
```

---

## Фінальна верифікація (вся фіча разом)

- [ ] **Резолв режиму (back-compat + override)**

Run:
```bash
ansible localhost -m debug -a "msg={{ 'letsencrypt' if nginx_letsencrypt | default(false) | bool else 'self_signed' }}"
ansible localhost -m debug -a "msg={{ 'letsencrypt' if nginx_letsencrypt | default(false) | bool else 'self_signed' }}" -e nginx_letsencrypt=true
```
Expected: `self_signed`, потім `letsencrypt`.

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

- [ ] **(Опційно, на реальному nginx-хості) перевірити patch + nginx -t**

Run на провіженому nginx-хості:
```bash
grep -E 'ssl_certificate|server_name' /etc/nginx/sites-enabled/default
nginx -t
```
Expected: `ssl_certificate`/`ssl_certificate_key` вказують на `/etc/nginx/ssl/<site>.{crt,key}`, `server_name` = `nginx_site_name`, `nginx -t` → `syntax is ok` / `test is successful`.
```
