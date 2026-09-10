# postgres_common Substrate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Commit policy:** The repo owner requires explicit approval before any `git commit`. Commit steps below are written as the convention, but the executor MUST pause and ask before running them.

**Goal:** Eliminate duplicated package-install and DB-bootstrap logic between the `postgres` (standalone) and `patroni` (HA) roles by extracting a shared `postgres_common` substrate role, without touching inventory, preflight, or `playbooks/database.yml`.

**Architecture:** New `postgres_common` role exposes two entry points — `tasks/install.yml` (PGDG/TimescaleDB repos + base packages) and `tasks/configure.yml` (create user/db, fix SQL-dir perms, restore schema). Both `postgres` and `patroni` call these via `ansible.builtin.include_role` with `tasks_from:` at the correct point in their own `main.yml`, passing connection/identity vars through `vars:`. Role-specific config (standalone `postgresql.conf`/`pg_hba`/cron vs Patroni template/unit-disable/leader-gate) stays in each role.

**Tech Stack:** Ansible (ansible-core 2.21), `community.postgresql`, `ansible.builtin.deb822_repository`; verification via `yamllint` + `ansible-lint` (production profile) + `ansible-playbook --syntax-check`.

**Verification model:** This is an Ansible refactor with no unit-test framework. "Tests" = `yamllint`, `ansible-lint`, and `--syntax-check` across the example inventories (mirrors CI in `.github/workflows/reviewdog.yml`). Behavioural equivalence is verified by a manual run in the OrbStack test env (final task).

**Key constraint — variable naming:** `ansible-lint` production profile rule `var-naming[no-role-prefix]` requires role defaults to be prefixed with the role name. The common role's interface vars are therefore `postgres_common_*`. Vars read **outside** the common role in tag-isolated blocks (`patroni_app_user` in the template; `postgres_db` in the cron) stay in the consuming role's defaults and are passed into common via `vars:`.

---

### Task 1: Create `postgres_common` role skeleton (defaults + README)

**Files:**
- Create: `roles/postgres_common/defaults/main.yml`
- Create: `roles/postgres_common/README.md`

- [ ] **Step 1: Write `roles/postgres_common/defaults/main.yml`**

```yaml
---
# pg_major НЕ задаємо тут — це факт із preflight set_fact (15|18), доступний
# глобально; шляхи нижче читають його напряму.

# Webitel application DB identity (джерело правди; споживачі передають через vars:)
postgres_common_db: webitel
postgres_common_app_user: opensips
postgres_common_app_password: webitel
postgres_common_schema_files:
  - "/usr/share/postgresql/{{ pg_major }}/webitel/webitel-db-schema.sql"
  - "/usr/share/postgresql/{{ pg_major }}/webitel/webitel-db-data.sql"

# Базові пакети (репозиторії спільні для standalone і HA)
postgres_common_base_packages:
  - "postgresql-{{ pg_major }}"
  - "timescaledb-2-postgresql-{{ pg_major }}"
  - "webitel-postgresql-{{ pg_major }}"
  - "webitel-postgresql-migrations-{{ pg_major }}"

postgres_common_pgdg_keyring: /usr/share/keyrings/postgresql.gpg
postgres_common_timescale_keyring: /usr/share/keyrings/timescaledb.gpg

# Спосіб підключення для бутстрапу БД.
# Порожній login_host → peer-auth через локальний сокет (become_user: postgres).
# Непорожній (напр. 127.0.0.1) → TCP з кредами (Patroni-лідер).
postgres_common_login_host: ""
postgres_common_login_user: ""
postgres_common_login_password: ""
```

- [ ] **Step 2: Write `roles/postgres_common/README.md`**

```markdown
# Role: postgres_common

Спільний субстрат для ролей `postgres` (standalone) і `patroni` (HA). Виносить
дубльовану логіку, щоб не копіпастити її в обох ролях:

- `tasks/install.yml` — репозиторії PGDG + TimescaleDB (GPG-ключі, `deb822_repository`)
  і встановлення базового списку пакетів `postgres_common_base_packages`.
- `tasks/configure.yml` — бутстрап Webitel БД: create app user, create database,
  fix прав на SQL-каталог, restore схеми/даних.

Роль не має `tasks/main.yml` — її викликають лише через
`include_role: { name: postgres_common, tasks_from: install | configure }`.

## Інтерфейс (variables)

| Variable | Default | Description |
|---|---|---|
| `postgres_common_db` | `webitel` | Ім'я Webitel-бази |
| `postgres_common_app_user` | `opensips` | Прикладний користувач БД (SUPERUSER) |
| `postgres_common_app_password` | `webitel` | Пароль прикладного користувача |
| `postgres_common_schema_files` | 2 SQL-файли під `/usr/share/postgresql/{{ pg_major }}/webitel/` | Файли схеми/даних для restore |
| `postgres_common_base_packages` | список | Базові пакети (pg, timescaledb, webitel ext + migrations) |
| `postgres_common_pgdg_keyring` | `/usr/share/keyrings/postgresql.gpg` | Шлях до PGDG keyring |
| `postgres_common_timescale_keyring` | `/usr/share/keyrings/timescaledb.gpg` | Шлях до TimescaleDB keyring |
| `postgres_common_login_host` | `""` | Порожній → peer-auth; `127.0.0.1` → TCP (Patroni-лідер) |
| `postgres_common_login_user` | `""` | Login user для TCP-режиму (superuser) |
| `postgres_common_login_password` | `""` | Login password для TCP-режиму |

`pg_major` (15|18) очікується з preflight `set_fact`.

## Споживання

```yaml
# install (на початку ролі-споживача)
- ansible.builtin.include_role:
    name: postgres_common
    tasks_from: install

# bootstrap (після configure ролі-споживача)
- ansible.builtin.include_role:
    name: postgres_common
    tasks_from: configure
  vars:
    postgres_common_db: "{{ postgres_db }}"   # приклад для standalone
```
```

- [ ] **Step 3: Verify yamllint passes on the new files**

Run: `yamllint roles/postgres_common/`
Expected: no output (exit 0).

- [ ] **Step 4: Commit (ask first — see commit policy)**

```bash
git add roles/postgres_common/defaults/main.yml roles/postgres_common/README.md
git commit -m "feat(postgres_common): add shared substrate role defaults and README"
```

---

### Task 2: Add `postgres_common/tasks/install.yml` (shared repos + base packages)

**Files:**
- Create: `roles/postgres_common/tasks/install.yml`

- [ ] **Step 1: Write `roles/postgres_common/tasks/install.yml`**

```yaml
---
- name: Download PGDG GPG key
  ansible.builtin.get_url:
    url: https://www.postgresql.org/media/keys/ACCC4CF8.asc
    dest: /tmp/pgdg.asc
    mode: "0644"

- name: Dearmor PGDG key
  ansible.builtin.command:
    cmd: gpg --batch --yes --dearmor -o {{ postgres_common_pgdg_keyring }} /tmp/pgdg.asc
    creates: "{{ postgres_common_pgdg_keyring }}"

- name: Download TimescaleDB GPG key
  ansible.builtin.get_url:
    url: https://packagecloud.io/timescale/timescaledb/gpgkey
    dest: /tmp/timescaledb.asc
    mode: "0644"

- name: Dearmor TimescaleDB key
  ansible.builtin.command:
    cmd: gpg --batch --yes --dearmor -o {{ postgres_common_timescale_keyring }} /tmp/timescaledb.asc
    creates: "{{ postgres_common_timescale_keyring }}"

- name: Add PGDG repository
  ansible.builtin.deb822_repository:
    name: postgresql
    types: [deb]
    uris: "http://apt.postgresql.org/pub/repos/apt/"
    suites: "{{ ansible_facts.distribution_release }}-pgdg"
    components: main
    signed_by: "{{ postgres_common_pgdg_keyring }}"
    state: present
    enabled: true

- name: Add TimescaleDB repository
  ansible.builtin.deb822_repository:
    name: timescaledb
    types: [deb]
    uris: "https://packagecloud.io/timescale/timescaledb/debian/"
    suites: "{{ ansible_facts.distribution_release }}"
    components: main
    signed_by: "{{ postgres_common_timescale_keyring }}"
    state: present
    enabled: true

- name: Install PostgreSQL, TimescaleDB and webitel base packages
  ansible.builtin.apt:
    name: "{{ postgres_common_base_packages }}"
    state: present
    install_recommends: false
    update_cache: true
```

- [ ] **Step 2: Verify yamllint + ansible-lint on the file**

Run: `yamllint roles/postgres_common/tasks/install.yml && ansible-lint roles/postgres_common/`
Expected: no findings (note: `ansible-lint` may still flag a missing `tasks/configure.yml` reference only if cross-referenced — it isn't yet, so expect clean).

- [ ] **Step 3: Commit (ask first)**

```bash
git add roles/postgres_common/tasks/install.yml
git commit -m "feat(postgres_common): add shared repo + base package install"
```

---

### Task 3: Add `postgres_common/tasks/configure.yml` (shared DB bootstrap)

**Files:**
- Create: `roles/postgres_common/tasks/configure.yml`

- [ ] **Step 1: Write `roles/postgres_common/tasks/configure.yml`**

Connection params use `| default(omit, true)` so an empty value means "not passed"
(peer-auth). `become_user: postgres` is used in both modes (matches current
behaviour of both roles).

```yaml
---
- name: Create application user
  community.postgresql.postgresql_user:
    name: "{{ postgres_common_app_user }}"
    password: "{{ postgres_common_app_password }}"
    role_attr_flags: SUPERUSER
    login_host: "{{ postgres_common_login_host | default(omit, true) }}"
    login_user: "{{ postgres_common_login_user | default(omit, true) }}"
    login_password: "{{ postgres_common_login_password | default(omit, true) }}"
  become: true
  become_user: postgres

- name: Create webitel database
  community.postgresql.postgresql_db:
    name: "{{ postgres_common_db }}"
    owner: "{{ postgres_common_app_user }}"
    login_host: "{{ postgres_common_login_host | default(omit, true) }}"
    login_user: "{{ postgres_common_login_user | default(omit, true) }}"
    login_password: "{{ postgres_common_login_password | default(omit, true) }}"
  become: true
  become_user: postgres
  register: postgres_common_create_db

# Пакет webitel-postgresql-migrations-{N} ставить каталог /usr/share/postgresql/N/webitel
# з режимом 644 (без +x) — у нього не можна зайти під postgres. Виправляємо на 755.
# (Раніше fix був лише в standalone-ролі; тут спільний — лагодить і Patroni-шлях.)
- name: Ensure webitel SQL directory is traversable
  ansible.builtin.file:
    path: "/usr/share/postgresql/{{ pg_major }}/webitel"
    state: directory
    mode: "0755"
    recurse: false

- name: Restore webitel schema and data  # noqa: no-handler
  community.postgresql.postgresql_db:
    name: "{{ postgres_common_db }}"
    owner: "{{ postgres_common_app_user }}"
    state: restore
    target: "{{ item }}"
    login_host: "{{ postgres_common_login_host | default(omit, true) }}"
    login_user: "{{ postgres_common_login_user | default(omit, true) }}"
    login_password: "{{ postgres_common_login_password | default(omit, true) }}"
  loop: "{{ postgres_common_schema_files }}"
  become: true
  become_user: postgres
  when: postgres_common_create_db is changed
```

- [ ] **Step 2: Verify yamllint + ansible-lint**

Run: `yamllint roles/postgres_common/tasks/configure.yml && ansible-lint roles/postgres_common/`
Expected: no findings.

- [ ] **Step 3: Commit (ask first)**

```bash
git add roles/postgres_common/tasks/configure.yml
git commit -m "feat(postgres_common): add shared webitel DB bootstrap"
```

---

### Task 4: Rewire `postgres` role to use `postgres_common`

**Files:**
- Modify: `roles/postgres/tasks/main.yml`
- Replace: `roles/postgres/tasks/install.yml` (now standalone extras only)
- Replace: `roles/postgres/tasks/database.yml` (now wrapper around common configure)
- Modify: `roles/postgres/defaults/main.yml` (remove moved vars)
- Modify: `roles/postgres/README.md` (variable table)

- [ ] **Step 1: Rewrite `roles/postgres/tasks/main.yml`**

```yaml
---
- name: Install shared PostgreSQL repos and base packages
  ansible.builtin.include_role:
    name: postgres_common
    tasks_from: install
    apply:
      tags: [postgres_install]
  tags: [postgres_install]

- name: Install standalone PostgreSQL extras
  ansible.builtin.include_tasks:
    file: install.yml
    apply:
      tags: [postgres_install]
  tags: [postgres_install]

- name: Configure PostgreSQL
  ansible.builtin.include_tasks:
    file: configure.yml
    apply:
      tags: [postgres_configure]
  tags: [postgres_configure]

- name: Bootstrap webitel database
  ansible.builtin.include_tasks:
    file: database.yml
    apply:
      tags: [postgres_database]
  tags: [postgres_database]
```

- [ ] **Step 2: Replace `roles/postgres/tasks/install.yml` with standalone extras only**

The PGDG/TimescaleDB repos + base packages now come from `postgres_common`. This
file keeps only what is standalone-specific: `timescaledb-tools` and the
`timescaledb-tune` step.

```yaml
---
- name: Install standalone-only packages
  ansible.builtin.apt:
    name:
      - timescaledb-tools
    state: present
    install_recommends: false
    update_cache: true

- name: Run timescaledb-tune
  ansible.builtin.command:
    cmd: >-
      timescaledb-tune --quiet --yes
      --pg-version={{ postgres_major }}
      --conf-path=/etc/postgresql/{{ postgres_major }}/main/postgresql.conf
  register: postgres_tune
  changed_when: postgres_tune.rc == 0
  notify: restart postgresql
```

- [ ] **Step 3: Replace `roles/postgres/tasks/database.yml` with a common-configure wrapper**

`flush_handlers` (ensures postgres is up with final config) and the helper-cron are
standalone-specific and stay here; the user/db/restore logic moves to common
(peer-auth — no `postgres_common_login_*` passed).

```yaml
---
- name: Flush handlers so postgresql is up with final config
  ansible.builtin.meta: flush_handlers

- name: Bootstrap webitel database (shared, peer auth)
  ansible.builtin.include_role:
    name: postgres_common
    tasks_from: configure
  vars:
    postgres_common_db: "{{ postgres_db }}"

- name: Install daily helper cron
  ansible.builtin.cron:
    name: psql daily script
    minute: "4"
    hour: "4"
    user: postgres
    job: "psql {{ postgres_db }} < {{ postgres_helper_sql }}"
    cron_file: ansible_psql-database_helper
```

- [ ] **Step 4: Trim `roles/postgres/defaults/main.yml`**

Remove `postgres_packages`, `postgres_app_user`, `postgres_app_password`,
`postgres_schema_files`, `postgres_pgdg_keyring`, `postgres_timescale_keyring`
(all now in `postgres_common`). Keep the standalone-config and cron vars. Final file:

```yaml
---
postgres_major: "{{ pg_major }}"   # set_fact з preflight: 15 (Deb12) | 18 (Deb13)
postgres_listen_addresses: >-
  {{ 'localhost' if single_node | default(false)
     else 'localhost,' + ansible_facts.default_ipv4.address }}
postgres_max_connections: 150
postgres_db: webitel
postgres_helper_sql: "/usr/share/postgresql/{{ postgres_major }}/webitel/database_helper.sql"
```

- [ ] **Step 5: Update `roles/postgres/README.md` variable table**

Remove rows for `postgres_app_user`, `postgres_app_password`, `postgres_schema_files`,
`postgres_pgdg_keyring`, `postgres_timescale_keyring`. Add a sentence near the top:

> Базові пакети та бутстрап БД делеговані ролі `postgres_common` (репозиторії,
> пакети, create user/db, restore схеми). Налаштування користувача/пароля/схеми
> робиться через змінні `postgres_common_*` (див. `roles/postgres_common/README.md`).

Keep rows: `postgres_major`, `postgres_listen_addresses`, `postgres_max_connections`,
`postgres_db`, `postgres_helper_sql`.

- [ ] **Step 6: Verify yamllint + ansible-lint + syntax-check**

Run:
```bash
yamllint roles/postgres/
ansible-lint roles/postgres/ roles/postgres_common/
ansible-playbook --syntax-check -i inventories/singlehost.example site.yml
```
Expected: clean lint; syntax-check OK (`playbook: site.yml`).

- [ ] **Step 7: Commit (ask first)**

```bash
git add roles/postgres/ roles/postgres_common/
git commit -m "refactor(postgres): use postgres_common for repos and DB bootstrap"
```

---

### Task 5: Rewire `patroni` role to use `postgres_common`

**Files:**
- Modify: `roles/patroni/tasks/main.yml`
- Replace: `roles/patroni/tasks/install.yml` (Patroni extras + node prep only)
- Replace: `roles/patroni/tasks/bootstrap_db.yml` (leader-gate wrapper around common configure)
- Modify: `roles/patroni/defaults/main.yml` (remove moved vars; fix migrations package)
- Modify: `roles/patroni/README.md` (variable table)
- Unchanged: `roles/patroni/tasks/configure.yml`, `roles/patroni/templates/patroni.yml.j2`, `roles/patroni/handlers/main.yml`

- [ ] **Step 1: Rewrite `roles/patroni/tasks/main.yml`**

```yaml
---
- name: Install shared PostgreSQL repos and base packages
  ansible.builtin.include_role:
    name: postgres_common
    tasks_from: install
    apply:
      tags: [patroni_install]
  tags: [patroni_install]

- name: Install Patroni packages and prepare node
  ansible.builtin.include_tasks:
    file: install.yml
    apply:
      tags: [patroni_install]
  tags: [patroni_install]

- name: Configure Patroni
  ansible.builtin.include_tasks:
    file: configure.yml
    apply:
      tags: [patroni_configure]
  tags: [patroni_configure]

# Bootstrap виконуємо лише з першої ноди кластера — під serial:1 саме вона
# стартує першою і стає початковим лідером. /leader-перевірка всередині —
# вторинний запобіжник (на не-лідері поверне 503 і блок пропуститься).
- name: Bootstrap Webitel database
  ansible.builtin.include_tasks:
    file: bootstrap_db.yml
    apply:
      tags: [patroni_bootstrap]
  when: inventory_hostname == (patroni_cluster_hosts | first)
  tags: [patroni_bootstrap]
```

- [ ] **Step 2: Replace `roles/patroni/tasks/install.yml` with Patroni extras + node prep**

Repos + base packages now come from `postgres_common`. This file keeps only the
Patroni-specific packages and the native-cluster teardown. Note the previous
`webitel-postgresql-migrations` (no major suffix) is dropped — the correctly-named
`webitel-postgresql-migrations-{N}` is in `postgres_common_base_packages`.

```yaml
---
- name: Install Patroni and Consul integration packages
  ansible.builtin.apt:
    name:
      - patroni
      - python3-consul
    state: present
    install_recommends: false
    update_cache: true

- name: Disable native postgresql unit (Patroni manages PostgreSQL)
  ansible.builtin.systemd_service:
    name: postgresql
    enabled: false
    state: stopped
  failed_when: false

- name: Remove auto-created postgresql cluster (Patroni bootstraps its own)
  ansible.builtin.command:
    cmd: "pg_dropcluster --stop {{ patroni_major }} main"
    removes: "/etc/postgresql/{{ patroni_major }}/main/postgresql.conf"
```

- [ ] **Step 3: Replace `roles/patroni/tasks/bootstrap_db.yml` with leader-wait + common configure**

The leader REST-endpoint wait stays here; the user/db/restore logic moves to common,
invoked in TCP mode (login via 127.0.0.1 with superuser creds). `patroni_app_user`
stays in patroni defaults (the template reads it) and is passed in as
`postgres_common_app_user`.

```yaml
---
- name: Wait for Patroni leader REST endpoint
  ansible.builtin.uri:
    url: "{{ 'https' if patroni_tls_enabled | bool else 'http' }}://{{ patroni_node_ip }}:8008/leader"
    validate_certs: false
    status_code: [200, 503]
  register: patroni_leader_check
  until: patroni_leader_check.status == 200
  retries: 30
  delay: 5
  changed_when: false
  failed_when: false

- name: Bootstrap webitel database on the leader only (shared, TCP auth)
  when: patroni_leader_check.status == 200
  ansible.builtin.include_role:
    name: postgres_common
    tasks_from: configure
  vars:
    postgres_common_app_user: "{{ patroni_app_user }}"
    postgres_common_login_host: "127.0.0.1"
    postgres_common_login_user: "{{ patroni_superuser_user }}"
    postgres_common_login_password: "{{ patroni_superuser_password }}"
```

- [ ] **Step 4: Trim `roles/patroni/defaults/main.yml`**

Remove `patroni_packages`, `patroni_app_password`, `patroni_db`,
`patroni_schema_files`, `patroni_pgdg_keyring`, `patroni_timescale_keyring`.
**Keep `patroni_app_user`** (read by `patroni.yml.j2`). Keep all DCS/TLS/cred vars.
Resulting file:

```yaml
---
patroni_major: "{{ pg_major }}"      # set_fact з preflight (15|18)
patroni_scope: "{{ webitel_patroni_scope | default('webitel-postgres') }}"
patroni_cluster_hosts: >-
  {{ groups['patroni'] | default([])
     | map('extract', hostvars)
     | selectattr('datacenter', 'defined')
     | selectattr('datacenter', '==', datacenter | default('dc1'))
     | map(attribute='inventory_hostname') | list
     or groups['patroni'] | default([]) }}
patroni_node_ip: "{{ ansible_facts.default_ipv4.address }}"
patroni_failover_priority: "{{ hostvars[inventory_hostname].patroni_priority | default(1) }}"
# DCS
patroni_consul_host: "127.0.0.1:8500"
# TLS для restapi/ctl
patroni_tls_enabled: "{{ consul_pki_enabled | default(false) }}"
patroni_ssl_dir: "{{ pki_remote_dir | default('/etc/ssl/app') }}"
# Креденшіали (vault у проді)
patroni_superuser_user: admin
patroni_superuser_password: "{{ vault_patroni_superuser_password | default('webitel') }}"
patroni_replication_user: replication
patroni_replication_password: "{{ vault_patroni_replication_password | default('webitel') }}"
patroni_rewind_user: rewind
patroni_rewind_password: "{{ vault_patroni_rewind_password | default('webitel') }}"
patroni_restapi_user: patroni
patroni_restapi_password: "{{ vault_patroni_restapi_password | default('webitel') }}"
# Webitel application DB user (читається в patroni.yml.j2; решта DB-параметрів у postgres_common)
patroni_app_user: opensips
```

- [ ] **Step 5: Update `roles/patroni/README.md` variable table**

Remove rows for `patroni_app_password`, `patroni_db`, `patroni_schema_files`, and the
`patroni_packages` description. Keep `patroni_app_user`. Add near the top:

> Репозиторії, базові пакети та бутстрап БД делеговані ролі `postgres_common`.
> DB-параметри (`*_app_password`, `*_db`, `*_schema_files`) задаються через
> `postgres_common_*` (див. `roles/postgres_common/README.md`).

- [ ] **Step 6: Verify yamllint + ansible-lint + syntax-check**

Run:
```bash
yamllint roles/patroni/
ansible-lint roles/patroni/ roles/postgres_common/
ansible-playbook --syntax-check -i inventories/failover.example site.yml
```
Expected: clean lint; syntax-check OK.

- [ ] **Step 7: Commit (ask first)**

```bash
git add roles/patroni/ roles/postgres_common/
git commit -m "refactor(patroni): use postgres_common; fix migrations package name"
```

---

### Task 6: Full repo verification + spec status

**Files:**
- Modify: `docs/superpowers/specs/2026-06-13-postgres-common-substrate-design.md` (status)

- [ ] **Step 1: Run the full CI-equivalent lint + syntax-check matrix**

```bash
yamllint .
ansible-lint
ansible-playbook --syntax-check -i inventories/singlehost.example     site.yml
ansible-playbook --syntax-check -i inventories/multihost.example       site.yml
ansible-playbook --syntax-check -i inventories/failover.example        site.yml
ansible-playbook --syntax-check -i inventories/warm-standby-2dc.example site.yml
```
Expected: all clean / all `--syntax-check` pass. Fix any `var-naming[no-role-prefix]`
or undefined-var findings before proceeding.

- [ ] **Step 2: Confirm no orphaned references to removed vars**

```bash
grep -rnE "postgres_(packages|app_user|app_password|schema_files|pgdg_keyring|timescale_keyring)" roles/ playbooks/
grep -rnE "patroni_(packages|app_password|db|schema_files|pgdg_keyring|timescale_keyring)" roles/ playbooks/ roles/patroni/templates/
```
Expected: no matches (README mentions are fine but should already be updated).

- [ ] **Step 3: Functional run in OrbStack test env (manual, behavioural equivalence)**

Standalone:
```bash
ansible-playbook -i inventories/singlehost.example site.yml --tags postgres_install,postgres_configure,postgres_database
```
Confirm on host: base packages incl. `webitel-postgresql-migrations-{N}` installed,
DB `webitel` exists, schema loaded, `/usr/share/postgresql/{N}/webitel` is `0755`,
helper cron present.

Patroni (HA inventory):
```bash
ansible-playbook -i inventories/failover.example site.yml --tags patroni_install,patroni_configure,patroni_bootstrap
```
Confirm: cluster up, leader bootstrapped `webitel`, SQL dir traversable, replicas
streaming. Re-run once to confirm idempotence (no unexpected changed tasks).

- [ ] **Step 4: Mark the spec implemented**

Edit `docs/superpowers/specs/2026-06-13-postgres-common-substrate-design.md`:
change `**Статус:** дизайн затверджено, очікує плану імплементації` →
`**Статус:** реалізовано`.

- [ ] **Step 5: Commit (ask first)**

```bash
git add docs/superpowers/specs/2026-06-13-postgres-common-substrate-design.md
git commit -m "docs: mark postgres_common substrate spec as implemented"
```

---

## Self-Review notes

- **Spec coverage:** install dedup → Task 2; bootstrap dedup → Task 3; thin `postgres` → Task 4; thin `patroni` + migrations-package fix + SQL-dir-fix-now-shared → Tasks 3 & 5; defaults single-source + naming nuance → Tasks 1/4/5; inventory/preflight/`database.yml` untouched → confirmed (no tasks modify them).
- **Var consistency:** common interface uniformly `postgres_common_*`; `register: postgres_common_create_db` defined in Task 3 and gated in the same file; `patroni_app_user` retained in Task 5 Step 4 and consumed by both the template (unchanged) and the bootstrap `vars:`; `postgres_db` retained in Task 4 Step 4 and consumed by both cron and the bootstrap `vars:`.
- **Behavioural equivalence:** standalone restore adds `owner` (already present before); patroni restore now also passes `owner` (additive, harmless) and gains the SQL-dir-fix (fixes latent bug). `become_user: postgres` preserved in both modes.
