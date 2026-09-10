# Topology Profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Замінити чотири незалежні `*_allow_*` булеві на один оголошуваний
`topology_profile` з жорстким гейтом preflight, і реалізувати профіль `stretch`
(один Patroni-кластер на ≥3 DC).

**Architecture:** Інвентар оголошує `topology_profile`. Таблиця профілів у
`roles/topology/vars/main.yml` — єдине джерело істини про очікуваний scope кожного
компонента. Плейбук `playbooks/validate_topology.yml` (тільки `hosts: localhost`,
без фактів і SSH) звіряє похідну з інвентаря реальність з таблицею. Роль
`topology` виводить з профілю один прапорець `_topology_db_scope` (`dc` | `global`),
який читають ролі `consul`, `patroni`, `haproxy`.

**Tech Stack:** Ansible-core, `ansible.builtin.constructed` inventory plugin,
ansible-lint (profile `production`), yamllint, bash.

**Spec:** `docs/superpowers/specs/2026-09-10-topology-profiles-design.md`

## Global Constraints

- **Не комітити без явного дозволу користувача.** Кроки «Commit» у цьому плані
  виконувати лише після того, як користувач це підтвердив. Це чинна конвенція
  проєкту, вона перекриває дефолт «frequent commits».
- П'ять і тільки п'ять значень `topology_profile`: `singlehost`, `multihost`,
  `failover`, `warm_standby`, `stretch`. Будь-яке інше значення або його
  відсутність = відмова preflight.
- `warm_standby` — DC ≥ 2. `stretch` — DC ≥ 3. `singlehost` — рівно 1 хост.
  `multihost` і `failover` — рівно 1 DC.
- Consul присутній у **кожному** профілі: асерт «кожен DC з хостами має ≥1
  `consul_server`» лишається безумовним.
- RabbitMQ-кластер і `nomad_server` **не перетинають DC в жодному профілі**,
  включно зі `stretch`.
- Кворум DCS непарний і ≥3 у `failover`, `warm_standby`, `stretch`.
- У `stretch` сервери DCS живуть **рівно у трьох** fault domains незалежно від
  загальної к-ті DC.
- Ansible **не має права** торкатися `standby_cluster` на вже ініціалізованому
  кластері (guard через Patroni REST). Це поза цим планом, але жоден таск плану
  не має цю межу порушувати.
- Кожна зміна має проходити `yamllint .` і `ansible-lint` (profile `production`)
  без нових зауважень — це те, що виконує CI-джоба `validate`.
- Мова коментарів у коді — англійська (як у наявних ролях). Мова документів у
  `docs/` і `README.md` — українська, крім `README.md`, який англійською.
- **Кожна фікстура мусить містити `dns_upstream_servers` у `all.vars`.** Асерт
  `dns_upstream_servers must be set on every host` живе у другому play, тобто
  переїжджає у `validate_topology.yml` разом з рештою, і спрацьовує на будь-якому
  інвентарі з >1 хостом. Без цього рядка фікстура впаде не на тому асерті, який
  вона перевіряє. Значення довільне, напр. `[10.0.0.1]`.

---

## File Structure

**Створюється:**

| Файл | Відповідальність |
|---|---|
| `roles/topology/vars/main.yml` | таблиця `topology_profiles` — єдине джерело істини про очікуваний scope. `vars/` (не `defaults/`), бо це константа, яку користувач не перевизначає |
| `playbooks/validate_topology.yml` | усі перевірки, що потребують лише даних інвентаря; `hosts: localhost`, без SSH |
| `tests/run.sh` | ганяє `validate_topology.yml` проти фікстур, звіряє rc і текст помилки |
| `tests/cases.txt` | таблиця «фікстура \| очікуваний rc \| очікуваний фрагмент повідомлення» |
| `tests/fixtures/*.yml` | мінімальні інвентарі-фікстури, по одному файлу на випадок |
| `roles/consul/tasks/prepared_queries_one.yml` | створення prepared queries на **одному** Consul-кластері |

**Змінюється:**

| Файл | Що саме |
|---|---|
| `playbooks/preflight.yml` | другий play (`Preflight topology checks`) виноситься у `validate_topology.yml`; у файлі лишається тільки перший play |
| `site.yml` | імпорт `validate_topology.yml` перед `preflight.yml` |
| `roles/topology/tasks/main.yml` | `set_fact: _topology_db_scope` з профілю |
| `roles/consul/defaults/main.yml` | `consul_datacenter` і `consul_server_hosts` враховують `_topology_db_scope` |
| `roles/patroni/defaults/main.yml` | `patroni_cluster_hosts` враховує `_topology_db_scope`; додаються тайминги |
| `roles/patroni/templates/patroni.yml.j2` | `synchronous_mode`, `ttl`/`loop_wait`/`retry_timeout` |
| `roles/haproxy/defaults/main.yml` | `haproxy_backends` враховує `_topology_db_scope` |
| `roles/consul/templates/consul.hcl.j2` | блок `performance { raft_multiplier }` |
| `roles/consul/tasks/prepared_queries.yml` | стає диспетчером-циклом по кластерах |
| `inventories/*.example/group_vars/all/main.yml` | додається `topology_profile` |
| `inventories/warm-standby-2dc.example/group_vars/all/main.yml` | додається `primary_datacenter: dc_a` |
| `.github/workflows/reviewdog.yml` | крок `tests/run.sh` |
| `README.md` | таблиця схем замінюється матрицею профілів |

**Не входить у план** (окремі рішення, зафіксовані у спеці):
реалізація `standby_cluster` (є власний план `2026-06-17-patroni-warm-standby-2dc.md`),
локальність читань у `stretch`, guard Patroni REST проти відкату promote.

---

### Task 1: Тестовий харнес і винесення перевірок топології

Зараз перевірки топології живуть другим play у `playbooks/preflight.yml`. Play уже
`hosts: localhost, gather_facts: false`, тобто працює **без SSH і без фактів** —
але запустити його окремо не можна, бо перший play у тому ж файлі йде на `all`.
Виносимо його в окремий файл, і з цього виникає повноцінний цикл червоне/зелене.

**Files:**
- Create: `playbooks/validate_topology.yml`
- Create: `tests/run.sh`
- Create: `tests/cases.txt`
- Create: `tests/fixtures/valid-failover.yml`
- Modify: `playbooks/preflight.yml` (видалити другий play, рядки 124–кінець)
- Modify: `site.yml`

**Interfaces:**
- Produces: плейбук `playbooks/validate_topology.yml`, який усі наступні таски
  наповнюють асертами; харнес `tests/run.sh`, який усі наступні таски
  використовують як тест-раннер; формат рядка `tests/cases.txt` —
  `<ім'я фікстури без .yml>|<очікуваний rc>|<очікуваний фрагмент stdout>`.

- [ ] **Step 1: Створити фікстуру валідного failover**

`tests/fixtures/valid-failover.yml`:

```yaml
---
all:
  vars:
    topology_profile: failover
    dns_upstream_servers: [10.0.0.1]
  children:
    dc1:
      vars:
        datacenter: dc1
      hosts:
        db1: {}
        db2: {}
        db3: {}
    patroni:
      hosts:
        db1: {}
        db2: {}
        db3: {}
    consul_server:
      hosts:
        db1: {}
        db2: {}
        db3: {}
    rabbitmq:
      hosts:
        db1: {}
        db2: {}
        db3: {}
```

- [ ] **Step 2: Створити раннер**

`tests/run.sh`:

```bash
#!/usr/bin/env bash
# Runs playbooks/validate_topology.yml against every fixture listed in
# tests/cases.txt and compares exit code and message with the expectation.
# The playbook targets localhost only, so no SSH or managed hosts are needed.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

failed=0
while IFS='|' read -r fixture expected_rc expected_msg; do
    [[ -z "${fixture// }" || "${fixture}" == \#* ]] && continue
    output=$(ansible-playbook -i "tests/fixtures/${fixture}.yml" \
        playbooks/validate_topology.yml 2>&1)
    rc=$?
    if [[ "${rc}" -ne "${expected_rc}" ]]; then
        echo "FAIL ${fixture}: rc=${rc}, expected ${expected_rc}"
        echo "${output}" | tail -20
        failed=1
        continue
    fi
    if [[ -n "${expected_msg// }" ]] && ! grep -qF "${expected_msg}" <<<"${output}"; then
        echo "FAIL ${fixture}: output does not contain '${expected_msg}'"
        echo "${output}" | tail -20
        failed=1
        continue
    fi
    echo "ok   ${fixture}"
done < tests/cases.txt

exit "${failed}"
```

Зробити виконуваним: `chmod +x tests/run.sh`

- [ ] **Step 3: Створити таблицю випадків**

`tests/cases.txt`:

```
# fixture|expected_rc|expected message fragment
valid-failover|0|
```

- [ ] **Step 4: Запустити раннер і переконатись, що він падає**

Run: `./tests/run.sh`
Expected: FAIL — `playbooks/validate_topology.yml` ще не існує, rc буде не 0.

- [ ] **Step 5: Створити плейбук перенесенням другого play**

Створити `playbooks/validate_topology.yml`, перенісши туди **дослівно** другий
play з `playbooks/preflight.yml` (він починається рядком
`- name: Preflight topology checks (cross-host)` і триває до кінця файлу).
Заголовок play привести до:

```yaml
---
# Every check here reads only inventory data (groups, static hostvars), never
# facts, so the play runs against any inventory without SSH. tests/run.sh
# relies on that: it is the whole test cycle for topology validation.
- name: Validate topology
  hosts: localhost
  gather_facts: false
  any_errors_fatal: "{{ fail_fast | default(true) }}"
  tags: [always]
  tasks:
```

Тіло тасків не змінювати — на цьому кроці це чисте перенесення.

- [ ] **Step 6: Прибрати перенесений play з preflight.yml**

Видалити з `playbooks/preflight.yml` усе, починаючи з рядка
`- name: Preflight topology checks (cross-host)` і до кінця файлу. У файлі
лишається один play — `Preflight checks` на `hosts: all`.

- [ ] **Step 7: Підключити новий плейбук у site.yml**

У `site.yml` перед імпортом preflight додати:

```yaml
- name: Validate topology against the declared profile
  ansible.builtin.import_playbook: playbooks/validate_topology.yml
```

- [ ] **Step 8: Запустити раннер і переконатись, що він проходить**

Run: `./tests/run.sh`
Expected: `ok   valid-failover`, rc=0

- [ ] **Step 9: Перевірити, що нічого не зламалось у прикладах**

Run:
```bash
for inv in singlehost multihost failover warm-standby-2dc; do
  ansible-playbook --syntax-check -i "inventories/${inv}.example" site.yml || echo "BROKEN: ${inv}"
done
yamllint . && ansible-lint
```
Expected: усі syntax-check проходять, lint без нових зауважень.

- [ ] **Step 10: Commit** (лише з дозволу користувача — див. Global Constraints)

```bash
git add tests playbooks/validate_topology.yml playbooks/preflight.yml site.yml
git commit -m "test: extract topology checks into an offline-testable playbook"
```

---

### Task 2: Оголошення `topology_profile` і whitelist

**Files:**
- Create: `roles/topology/vars/main.yml`
- Create: `tests/fixtures/invalid-no-profile.yml`
- Create: `tests/fixtures/invalid-unknown-profile.yml`
- Modify: `playbooks/validate_topology.yml`
- Modify: `tests/cases.txt`

**Interfaces:**
- Consumes: `playbooks/validate_topology.yml` і `tests/run.sh` з Task 1.
- Produces: словник `topology_profiles` у `roles/topology/vars/main.yml` з ключами
  `implemented`, `min_datacenters`, `max_datacenters`, `max_hosts`, `db`,
  `dcs_scope`, `requires_primary_datacenter`. Значення `db`: `standalone`,
  `cluster`, `standby`. Значення `dcs_scope`: `dc`, `global`. `max_datacenters: 0`
  і `max_hosts: 0` означають «без верхньої межі». Наступні таски читають цей
  словник як `topology_profiles[topology_profile]`.

- [ ] **Step 1: Написати фікстури, що мають падати**

`tests/fixtures/invalid-no-profile.yml`:

```yaml
---
all:
  children:
    dc1:
      vars:
        datacenter: dc1
      hosts:
        node1: {}
    consul_server:
      hosts:
        node1: {}
```

`tests/fixtures/invalid-unknown-profile.yml`:

```yaml
---
all:
  vars:
    topology_profile: hyperscale
    dns_upstream_servers: [10.0.0.1]
  children:
    dc1:
      vars:
        datacenter: dc1
      hosts:
        node1: {}
    consul_server:
      hosts:
        node1: {}
```

- [ ] **Step 2: Додати випадки в таблицю**

Дописати в `tests/cases.txt`:

```
invalid-no-profile|2|topology_profile is not set
invalid-unknown-profile|2|Unknown topology_profile 'hyperscale'
```

- [ ] **Step 3: Запустити і переконатись, що падає**

Run: `./tests/run.sh`
Expected: два FAIL — `rc=0, expected 2` для обох нових фікстур, бо асерту ще немає.

- [ ] **Step 4: Створити таблицю профілів**

`roles/topology/vars/main.yml`:

```yaml
---
# Single source of truth for what each deployment profile is allowed to look
# like. Lives in vars/ (not defaults/) because it is a constant contract, not a
# tunable: overriding it in group_vars would defeat the gate.
#
# max_datacenters / max_hosts: 0 means no upper bound.
# db:        standalone (plain postgres) | cluster (one patroni cluster) |
#            standby   (primary cluster + N standby clusters)
# dcs_scope: dc (one Consul cluster per datacenter) | global (one across all)
topology_profiles:
  singlehost:
    implemented: true
    min_datacenters: 1
    max_datacenters: 1
    max_hosts: 1
    db: standalone
    dcs_scope: dc
    requires_primary_datacenter: false
  multihost:
    implemented: true
    min_datacenters: 1
    max_datacenters: 1
    max_hosts: 0
    db: standalone
    dcs_scope: dc
    requires_primary_datacenter: false
  failover:
    implemented: true
    min_datacenters: 1
    max_datacenters: 1
    max_hosts: 0
    db: cluster
    dcs_scope: dc
    requires_primary_datacenter: false
  warm_standby:
    implemented: true
    min_datacenters: 2
    max_datacenters: 0
    max_hosts: 0
    db: standby
    dcs_scope: dc
    requires_primary_datacenter: true
  stretch:
    # Flipped to true in the task that lands the global-scope roles.
    implemented: false
    min_datacenters: 3
    max_datacenters: 0
    max_hosts: 0
    db: cluster
    dcs_scope: global
    requires_primary_datacenter: false
```

- [ ] **Step 5: Підключити таблицю і додати асерти whitelist**

У `playbooks/validate_topology.yml` додати `vars_files` одразу після `tags`:

```yaml
  vars_files:
    - ../roles/topology/vars/main.yml
```

І першими тасками у списку `tasks:`:

```yaml
    - name: Validate | topology_profile must be declared
      ansible.builtin.assert:
        that:
          - topology_profile is defined
        fail_msg: >-
          topology_profile is not set. Declare it in group_vars/all/main.yml.
          Supported values: {{ topology_profiles.keys() | list | join(', ') }}.
        quiet: true

    - name: Validate | topology_profile must be a known profile
      ansible.builtin.assert:
        that:
          - topology_profile in topology_profiles
        fail_msg: >-
          Unknown topology_profile '{{ topology_profile }}'.
          Supported values: {{ topology_profiles.keys() | list | join(', ') }}.
        quiet: true

    - name: Validate | profile must be implemented
      ansible.builtin.assert:
        that:
          - topology_profiles[topology_profile].implemented | bool
        fail_msg: >-
          topology_profile '{{ topology_profile }}' is declared but not yet
          implemented in this version of the playbook.
        quiet: true
```

- [ ] **Step 6: Додати `topology_profile` у фікстуру valid-failover**

Фікстура вже містить `topology_profile: failover` з Task 1 — переконатись, що це так,
інакше додати в `all.vars`.

- [ ] **Step 7: Запустити і переконатись, що проходить**

Run: `./tests/run.sh`
Expected: три `ok` — `valid-failover`, `invalid-no-profile`, `invalid-unknown-profile`.

- [ ] **Step 8: Commit** (лише з дозволу)

```bash
git add roles/topology/vars/main.yml playbooks/validate_topology.yml tests
git commit -m "feat(topology): declare and whitelist topology_profile"
```

---

### Task 3: Перевірка к-ті датацентрів і хостів

**Files:**
- Create: `tests/fixtures/valid-singlehost.yml`
- Create: `tests/fixtures/invalid-singlehost-two-hosts.yml`
- Create: `tests/fixtures/invalid-warm-standby-1dc.yml`
- Create: `tests/fixtures/invalid-stretch-not-implemented.yml`
- Modify: `playbooks/validate_topology.yml`
- Modify: `tests/cases.txt`

**Interfaces:**
- Consumes: `topology_profiles[topology_profile]` з Task 2.
- Produces: факт `_validate_datacenters` — відсортований унікальний список DC
  усіх хостів інвентаря; використовується наступними тасками.

- [ ] **Step 1: Написати фікстури**

`tests/fixtures/valid-singlehost.yml`:

```yaml
---
all:
  vars:
    topology_profile: singlehost
    dns_upstream_servers: [10.0.0.1]
  children:
    dc1:
      vars:
        datacenter: dc1
      hosts:
        node1: {}
    consul_server:
      hosts:
        node1: {}
    postgres:
      hosts:
        node1: {}
    rabbitmq:
      hosts:
        node1: {}
```

`tests/fixtures/invalid-singlehost-two-hosts.yml`:

```yaml
---
all:
  vars:
    topology_profile: singlehost
    dns_upstream_servers: [10.0.0.1]
  children:
    dc1:
      vars:
        datacenter: dc1
      hosts:
        node1: {}
        node2: {}
    consul_server:
      hosts:
        node1: {}
    postgres:
      hosts:
        node1: {}
```

`tests/fixtures/invalid-warm-standby-1dc.yml` — профіль вимагає ≥2 DC:

```yaml
---
all:
  vars:
    topology_profile: warm_standby
    dns_upstream_servers: [10.0.0.1]
    primary_datacenter: dc_a
  children:
    dc_a:
      vars:
        datacenter: dc_a
      hosts:
        a1: {}
        a2: {}
        a3: {}
    patroni:
      hosts:
        a1: {}
        a2: {}
        a3: {}
    consul_server:
      hosts:
        a1: {}
        a2: {}
        a3: {}
```

`tests/fixtures/invalid-stretch-not-implemented.yml` — профіль у whitelist, але
`implemented: false` аж до таска, що вмикає глобальний scope:

```yaml
---
all:
  vars:
    topology_profile: stretch
    dns_upstream_servers: [10.0.0.1]
  children:
    dc1:
      vars:
        datacenter: dc1
      hosts:
        db1: {}
    dc2:
      vars:
        datacenter: dc2
      hosts:
        db2: {}
    dc3:
      vars:
        datacenter: dc3
      hosts:
        db3: {}
    patroni:
      hosts:
        db1: {}
        db2: {}
        db3: {}
    consul_server:
      hosts:
        db1: {}
        db2: {}
        db3: {}
```

- [ ] **Step 2: Додати випадки**

Дописати в `tests/cases.txt`:

```
valid-singlehost|0|
invalid-singlehost-two-hosts|2|allows at most 1 host
invalid-warm-standby-1dc|2|requires at least 2 datacenters
invalid-stretch-not-implemented|2|not yet implemented
```

`invalid-stretch-not-implemented` має проходити вже зараз — його ловить асерт
`implemented` з Task 2. Це навмисно: доки глобальний scope не реалізований,
`stretch` мусить відхилятися, і тест це фіксує. Правила самого `stretch`
тестуються в тому таску, який його вмикає.

- [ ] **Step 3: Запустити і переконатись, що падає рівно там, де треба**

Run: `./tests/run.sh`
Expected: `ok` для `invalid-stretch-not-implemented`; FAIL
(`rc=0, expected 2`) для `invalid-singlehost-two-hosts` і
`invalid-warm-standby-1dc`, бо асертів к-ті ще немає.

- [ ] **Step 4: Додати обчислення DC і асерти к-ті**

У `playbooks/validate_topology.yml`, після асертів whitelist:

```yaml
    - name: Validate | Resolve the datacenter list
      ansible.builtin.set_fact:
        _validate_datacenters: >-
          {{ groups['all'] | default([])
             | map('extract', hostvars)
             | selectattr('datacenter', 'defined')
             | map(attribute='datacenter')
             | unique | sort | list }}

    - name: Validate | Every host must declare a datacenter
      ansible.builtin.assert:
        that:
          - (groups['all'] | default([])) | length == 0
            or (_validate_datacenters | length) > 0
        fail_msg: >-
          No host declares a 'datacenter'. Set it in the inventory, per-DC group
          vars (see inventories/warm-standby-2dc.example/01-hosts.yml).
        quiet: true

    - name: Validate | Datacenter count must fit the profile
      ansible.builtin.assert:
        that:
          - (_validate_datacenters | length) >= topology_profiles[topology_profile].min_datacenters
          - topology_profiles[topology_profile].max_datacenters == 0
            or (_validate_datacenters | length) <= topology_profiles[topology_profile].max_datacenters
        fail_msg: >-
          Profile '{{ topology_profile }}' requires at least
          {{ topology_profiles[topology_profile].min_datacenters }} datacenters
          {%- if topology_profiles[topology_profile].max_datacenters > 0 %}
          and at most {{ topology_profiles[topology_profile].max_datacenters }}
          {%- endif %}, inventory has {{ _validate_datacenters | length }}
          ({{ _validate_datacenters | join(', ') }}).
        quiet: true

    - name: Validate | Host count must fit the profile
      ansible.builtin.assert:
        that:
          - topology_profiles[topology_profile].max_hosts == 0
            or (groups['all'] | default([])) | length <= topology_profiles[topology_profile].max_hosts
        fail_msg: >-
          Profile '{{ topology_profile }}' allows at most
          {{ topology_profiles[topology_profile].max_hosts }} host(s), inventory
          has {{ (groups['all'] | default([])) | length }}.
        quiet: true
```

- [ ] **Step 5: Запустити і переконатись, що проходить**

Run: `./tests/run.sh`
Expected: усі сім випадків `ok`.

- [ ] **Step 6: Commit** (лише з дозволу)

```bash
git add playbooks/validate_topology.yml tests
git commit -m "feat(topology): gate datacenter and host counts per profile"
```

---

### Task 4: Перевірка бази даних (standalone / cluster / standby)

**Files:**
- Create: `tests/fixtures/valid-warm-standby.yml`
- Create: `tests/fixtures/invalid-failover-with-postgres.yml`
- Create: `tests/fixtures/invalid-warm-standby-no-primary.yml`
- Modify: `playbooks/validate_topology.yml`
- Modify: `tests/cases.txt`

**Interfaces:**
- Consumes: `topology_profiles[topology_profile].db`,
  `topology_profiles[topology_profile].requires_primary_datacenter`,
  `_validate_datacenters` з Task 3.

- [ ] **Step 1: Написати фікстури**

`tests/fixtures/valid-warm-standby.yml`:

```yaml
---
all:
  vars:
    topology_profile: warm_standby
    dns_upstream_servers: [10.0.0.1]
    primary_datacenter: dc_a
  children:
    dc_a:
      vars:
        datacenter: dc_a
      hosts:
        a1: {}
        a2: {}
        a3: {}
    dc_b:
      vars:
        datacenter: dc_b
      hosts:
        b1: {}
        b2: {}
        b3: {}
    patroni:
      hosts:
        a1: {}
        a2: {}
        a3: {}
        b1: {}
        b2: {}
        b3: {}
    consul_server:
      hosts:
        a1: {}
        a2: {}
        a3: {}
        b1: {}
        b2: {}
        b3: {}
```

`tests/fixtures/invalid-failover-with-postgres.yml` — профіль вимагає patroni,
а інвентар дає standalone postgres:

```yaml
---
all:
  vars:
    topology_profile: failover
    dns_upstream_servers: [10.0.0.1]
  children:
    dc1:
      vars:
        datacenter: dc1
      hosts:
        node1: {}
        node2: {}
        node3: {}
    postgres:
      hosts:
        node1: {}
    consul_server:
      hosts:
        node1: {}
        node2: {}
        node3: {}
```

`tests/fixtures/invalid-warm-standby-no-primary.yml` — те саме, що
`valid-warm-standby.yml`, але **без** рядка `primary_datacenter: dc_a`:

```yaml
---
all:
  vars:
    topology_profile: warm_standby
    dns_upstream_servers: [10.0.0.1]
  children:
    dc_a:
      vars:
        datacenter: dc_a
      hosts:
        a1: {}
        a2: {}
        a3: {}
    dc_b:
      vars:
        datacenter: dc_b
      hosts:
        b1: {}
        b2: {}
        b3: {}
    patroni:
      hosts:
        a1: {}
        a2: {}
        a3: {}
        b1: {}
        b2: {}
        b3: {}
    consul_server:
      hosts:
        a1: {}
        a2: {}
        a3: {}
        b1: {}
        b2: {}
        b3: {}
```

- [ ] **Step 2: Додати випадки**

```
valid-warm-standby|0|
invalid-failover-with-postgres|2|expects a Patroni cluster
invalid-warm-standby-no-primary|2|requires primary_datacenter
```

- [ ] **Step 3: Запустити і переконатись, що падає**

Run: `./tests/run.sh`
Expected: FAIL для двох invalid-фікстур (`rc=0, expected 2`).

- [ ] **Step 4: Додати асерти БД**

```yaml
    - name: Validate | Standalone profiles must not define a Patroni cluster
      ansible.builtin.assert:
        that:
          - (groups['patroni'] | default([])) | length == 0
        fail_msg: >-
          Profile '{{ topology_profile }}' expects standalone PostgreSQL, but the
          inventory has {{ (groups['patroni'] | default([])) | length }} patroni
          host(s). Use profile 'failover' (1 DC) or 'warm_standby' (2+ DC).
        quiet: true
      when: topology_profiles[topology_profile].db == 'standalone'

    - name: Validate | Clustered profiles must define a Patroni cluster
      ansible.builtin.assert:
        that:
          - (groups['patroni'] | default([])) | length > 0
          - (groups['postgres'] | default([])) | length == 0
        fail_msg: >-
          Profile '{{ topology_profile }}' expects a Patroni cluster, but the
          inventory has {{ (groups['patroni'] | default([])) | length }} patroni
          host(s) and {{ (groups['postgres'] | default([])) | length }} standalone
          postgres host(s). Use profile 'multihost' for standalone PostgreSQL.
        quiet: true
      when: topology_profiles[topology_profile].db in ['cluster', 'standby']

    - name: Validate | Standby profiles require a primary datacenter
      ansible.builtin.assert:
        that:
          - primary_datacenter is defined
          - primary_datacenter in _validate_datacenters
        fail_msg: >-
          Profile '{{ topology_profile }}' requires primary_datacenter, set to one
          of {{ _validate_datacenters | join(', ') }}. Without it every datacenter
          would bootstrap its own primary and the data would diverge.
        quiet: true
      when: topology_profiles[topology_profile].requires_primary_datacenter | bool

    - name: Validate | Host cannot be in both 'postgres' and 'patroni'
      ansible.builtin.assert:
        that: >-
          (groups['postgres'] | default([]))
          | intersect(groups['patroni'] | default([]))
          | length == 0
        fail_msg: >-
          Hosts {{ (groups['postgres'] | default([])) | intersect(groups['patroni'] | default([])) | join(', ') }}
          are in both 'postgres' and 'patroni'. Patroni manages PostgreSQL itself.
        quiet: true
```

Останній асерт уже існує в файлі з Task 1 (перенесений з preflight) — якщо він там
є, не дублювати, лише переконатись, що формулювання збігається.

- [ ] **Step 5: Запустити і переконатись, що проходить**

Run: `./tests/run.sh`
Expected: усі десять випадків `ok`.

- [ ] **Step 6: Commit** (лише з дозволу)

```bash
git add playbooks/validate_topology.yml tests
git commit -m "feat(topology): gate database layout per profile"
```

---

### Task 5: Scope DCS, кворум, не-перетин RabbitMQ і Nomad; видалення чотирьох булевих

**Files:**
- Create: `tests/fixtures/invalid-failover-multidc.yml`
- Create: `tests/fixtures/invalid-even-quorum.yml`
- Create: `tests/fixtures/invalid-rabbitmq-multidc.yml`
- Create: `tests/fixtures/invalid-patroni-single-node.yml`
- Modify: `playbooks/validate_topology.yml`
- Modify: `tests/cases.txt`

**Interfaces:**
- Consumes: `topology_profiles[topology_profile].dcs_scope`, `_validate_datacenters`.
- Produces: жодних нових змінних; після цього таска змінні
  `consul_allow_multidc`, `patroni_allow_multidc`, `nomad_allow_multidc`,
  `rabbitmq_allow_stretch` більше не існують у репозиторії.

- [ ] **Step 1: Написати фікстури**

`tests/fixtures/invalid-failover-multidc.yml`:

```yaml
---
all:
  vars:
    topology_profile: failover
    dns_upstream_servers: [10.0.0.1]
  children:
    dc1:
      vars:
        datacenter: dc1
      hosts:
        db1: {}
        db2: {}
    dc2:
      vars:
        datacenter: dc2
      hosts:
        db3: {}
    patroni:
      hosts:
        db1: {}
        db2: {}
        db3: {}
    consul_server:
      hosts:
        db1: {}
        db2: {}
        db3: {}
```

`tests/fixtures/invalid-even-quorum.yml`:

```yaml
---
all:
  vars:
    topology_profile: failover
    dns_upstream_servers: [10.0.0.1]
  children:
    dc1:
      vars:
        datacenter: dc1
      hosts:
        db1: {}
        db2: {}
        db3: {}
        db4: {}
    patroni:
      hosts:
        db1: {}
        db2: {}
        db3: {}
    consul_server:
      hosts:
        db1: {}
        db2: {}
        db3: {}
        db4: {}
```

`tests/fixtures/invalid-rabbitmq-multidc.yml`:

```yaml
---
all:
  vars:
    topology_profile: warm_standby
    dns_upstream_servers: [10.0.0.1]
    primary_datacenter: dc_a
  children:
    dc_a:
      vars:
        datacenter: dc_a
      hosts:
        a1: {}
        a2: {}
        a3: {}
    dc_b:
      vars:
        datacenter: dc_b
      hosts:
        b1: {}
        b2: {}
        b3: {}
    patroni:
      hosts:
        a1: {}
        a2: {}
        a3: {}
        b1: {}
        b2: {}
        b3: {}
    consul_server:
      hosts:
        a1: {}
        a2: {}
        a3: {}
        b1: {}
        b2: {}
        b3: {}
    rabbitmq:
      hosts:
        a1: {}
        b1: {}
```

`tests/fixtures/invalid-patroni-single-node.yml` — кластер з однієї ноди:

```yaml
---
all:
  vars:
    topology_profile: failover
    dns_upstream_servers: [10.0.0.1]
  children:
    dc1:
      vars:
        datacenter: dc1
      hosts:
        db1: {}
        db2: {}
        db3: {}
    patroni:
      hosts:
        db1: {}
    consul_server:
      hosts:
        db1: {}
        db2: {}
        db3: {}
```

- [ ] **Step 2: Додати випадки**

```
invalid-failover-multidc|2|must live in a single datacenter
invalid-even-quorum|2|must be odd
invalid-rabbitmq-multidc|2|RabbitMQ cluster must not span datacenters
invalid-patroni-single-node|2|needs at least 2 nodes
```

- [ ] **Step 3: Запустити і переконатись, що падає**

Run: `./tests/run.sh`
Expected: FAIL для чотирьох нових випадків (`rc=0, expected 2`), окрім
`invalid-failover-multidc`, який наразі вже падає на перенесеному з preflight
асерті `patroni_allow_multidc` — але з іншим текстом, тож теж FAIL. Саме цей
асерт наступні кроки і замінюють.

- [ ] **Step 4: Видалити перенесені асерти з чотирма булевими**

У `playbooks/validate_topology.yml` видалити чотири таски, що прийшли з preflight
і посилаються на `consul_allow_multidc`, `patroni_allow_multidc`,
`nomad_allow_multidc`, `rabbitmq_allow_stretch`. Їхні назви:

- `Preflight | Consul_server cluster must be in a single datacenter (...)`
- `Preflight | Patroni cluster must not span datacenters (...)`
- `Preflight | RabbitMQ cluster must be in a single datacenter (...)`
- `Preflight | Nomad_server cluster must be in a single datacenter (...)`

Також видалити таск `Preflight | Multi-DC Patroni requires primary_datacenter`
— його замінив асерт `requires_primary_datacenter` з Task 4.

- [ ] **Step 5: Переконатись, що булевих ніде не лишилось**

Run: `grep -rn 'allow_multidc\|rabbitmq_allow_stretch' . --exclude-dir=.git`
Expected: жодного збігу поза `docs/`.

- [ ] **Step 6: Додати нові асерти scope і кворуму**

```yaml
    - name: Validate | Patroni cluster must live in a single datacenter
      ansible.builtin.assert:
        that: >-
          (groups['patroni'] | default([])
           | map('extract', hostvars)
           | map(attribute='datacenter')
           | unique | list | length) <= 1
        fail_msg: >-
          Profile '{{ topology_profile }}' keeps one Patroni cluster per
          datacenter, but the 'patroni' group spans
          {{ groups['patroni'] | map('extract', hostvars) | map(attribute='datacenter') | unique | join(', ') }}.
          Use 'warm_standby' for per-DC clusters with replication, or 'stretch'
          (3+ DC) for one cluster across datacenters.
        quiet: true
      when:
        - topology_profiles[topology_profile].dcs_scope == 'dc'
        - topology_profiles[topology_profile].db == 'cluster'

    - name: Validate | Every datacenter must have at least one consul_server
      ansible.builtin.assert:
        that: >-
          _validate_datacenters
          | difference(groups['consul_server'] | default([])
                       | map('extract', hostvars)
                       | map(attribute='datacenter') | unique | list)
          | length == 0
        fail_msg: >-
          Every datacenter must have at least one consul_server. Missing in:
          {{ _validate_datacenters | difference(groups['consul_server'] | default([]) | map('extract', hostvars) | map(attribute='datacenter') | unique | list) | join(', ') }}.
        quiet: true

    - name: Validate | Patroni cluster needs at least two nodes
      ansible.builtin.assert:
        that:
          - (item.1 | length) >= 2
        fail_msg: >-
          Patroni cluster in '{{ item.0 }}' has {{ item.1 | length }} node(s); it
          needs at least 2 nodes to fail over at all (3 recommended).
        quiet: true
      loop: >-
        {{ (groups['patroni'] | default([])
            | map('extract', hostvars)
            | groupby('datacenter'))
           if topology_profiles[topology_profile].dcs_scope == 'dc'
           else [['all datacenters', groups['patroni'] | default([])]] }}
      loop_control:
        label: "{{ item.0 }}"
      when: topology_profiles[topology_profile].db in ['cluster', 'standby']

    - name: Validate | DCS quorum must be odd and at least three
      ansible.builtin.assert:
        that:
          - (item.1 | length) >= 3
          - (item.1 | length) % 2 == 1
        fail_msg: >-
          consul_server count in '{{ item.0 }}' is {{ item.1 | length }}; it must
          be odd and at least 3. An even quorum tolerates no more failures than
          the odd size below it.
        quiet: true
      loop: >-
        {{ (groups['consul_server'] | default([])
            | map('extract', hostvars)
            | groupby('datacenter'))
           if topology_profiles[topology_profile].dcs_scope == 'dc'
           else [['all datacenters', groups['consul_server'] | default([])]] }}
      loop_control:
        label: "{{ item.0 }}"
      when: topology_profiles[topology_profile].db in ['cluster', 'standby']

    - name: Validate | RabbitMQ cluster must not span datacenters
      ansible.builtin.assert:
        that: >-
          (groups['rabbitmq'] | default([])
           | map('extract', hostvars)
           | map(attribute='datacenter')
           | unique | list | length) <= 1
        fail_msg: >-
          RabbitMQ cluster must not span datacenters in any profile; the group
          spans
          {{ groups['rabbitmq'] | map('extract', hostvars) | map(attribute='datacenter') | unique | join(', ') }}.
          Give each datacenter its own rabbitmq hosts.
        quiet: true

    - name: Validate | Nomad server cluster must not span datacenters
      ansible.builtin.assert:
        that: >-
          (groups['nomad_server'] | default([])
           | map('extract', hostvars)
           | map(attribute='datacenter')
           | unique | list | length) <= 1
        fail_msg: >-
          nomad_server must not span datacenters in any profile; the group spans
          {{ groups['nomad_server'] | map('extract', hostvars) | map(attribute='datacenter') | unique | join(', ') }}.
        quiet: true
```

- [ ] **Step 7: Запустити і переконатись, що проходить**

Run: `./tests/run.sh`
Expected: усі чотирнадцять випадків `ok`.

- [ ] **Step 8: Прогнати lint і syntax-check**

Run:
```bash
yamllint . && ansible-lint
for inv in singlehost multihost failover warm-standby-2dc; do
  ansible-playbook --syntax-check -i "inventories/${inv}.example" site.yml || echo "BROKEN: ${inv}"
done
```
Expected: чисто.

- [ ] **Step 9: Commit** (лише з дозволу)

```bash
git add playbooks/validate_topology.yml tests
git commit -m "feat(topology): replace four allow_* booleans with profile-driven gates"
```

---

### Task 6: Прапорець `_topology_db_scope` і глобальний Consul

**Files:**
- Modify: `roles/topology/tasks/main.yml`
- Modify: `roles/consul/defaults/main.yml`

**Interfaces:**
- Consumes: `topology_profiles` з `roles/topology/vars/main.yml` (авто-завантажується
  роллю), `topology_profile` з інвентаря.
- Produces: факт `_topology_db_scope` зі значенням `dc` або `global`, доступний
  усім ролям після `playbooks/topology.yml`; змінна `consul_global_datacenter`
  (дефолт `webitel`) — ім'я єдиного Consul-DC у профілі `stretch`.

- [ ] **Step 1: Вивести прапорець у ролі topology**

У `roles/topology/tasks/main.yml`, у таск `Resolve topology flags`, додати рядок:

```yaml
    _topology_db_scope: "{{ topology_profiles[topology_profile].dcs_scope }}"
```

`topology_profiles` доступний автоматично: Ansible завантажує `roles/topology/vars/main.yml`
разом з роллю.

- [ ] **Step 2: Перевірити, що прапорець виводиться**

Роль `topology` потребує фактів реальних хостів, тож прогнати її проти фікстур не
можна. Перевіряємо саме вираз, який щойно додали, через тимчасовий
localhost-плейбук:

```bash
cat > /tmp/probe-scope.yml <<'EOF'
---
- name: Probe scope
  hosts: localhost
  gather_facts: false
  vars_files:
    - "{{ playbook_dir }}/roles/topology/vars/main.yml"
  tasks:
    - name: Show resolved scope
      ansible.builtin.debug:
        msg: "{{ topology_profiles[topology_profile].dcs_scope }}"
EOF
ansible-playbook -i tests/fixtures/valid-stretch.yml /tmp/probe-scope.yml
ansible-playbook -i tests/fixtures/valid-failover.yml /tmp/probe-scope.yml
rm /tmp/probe-scope.yml
```
Expected: `global` для stretch, `dc` для failover.

- [ ] **Step 3: Зробити consul_datacenter залежним від scope**

У `roles/consul/defaults/main.yml` замінити:

```yaml
consul_datacenter: "{{ datacenter }}"
```

на:

```yaml
# In the stretch profile all sites form ONE Consul datacenter (a single raft),
# so the DC name must not vary per host. Everywhere else each site is its own
# isolated Consul datacenter.
consul_global_datacenter: webitel
consul_datacenter: >-
  {{ consul_global_datacenter
     if (_topology_db_scope | default('dc')) == 'global'
     else datacenter }}
```

- [ ] **Step 4: Зробити список серверів залежним від scope**

Замінити `consul_server_hosts` на:

```yaml
consul_server_hosts: >-
  {{ (groups['consul_server'] | default([]))
     if (_topology_db_scope | default('dc')) == 'global'
     else ((groups['consul_server'] | default([])
            | map('extract', hostvars)
            | selectattr('datacenter', 'defined')
            | selectattr('datacenter', '==', consul_datacenter)
            | map(attribute='inventory_hostname') | list)
           or (groups['consul_server'] | default([]))) }}
```

Це також автоматично виправляє `bootstrap_expect` і `retry_join` у
`roles/consul/templates/consul.hcl.j2` — обидва рахуються з `consul_server_hosts`.

- [ ] **Step 5: Перевірити рендер шаблону для обох scope**

Run:
```bash
yamllint . && ansible-lint
for inv in singlehost multihost failover warm-standby-2dc; do
  ansible-playbook --syntax-check -i "inventories/${inv}.example" site.yml || echo "BROKEN: ${inv}"
done
./tests/run.sh
```
Expected: чисто, усі тести `ok`.

- [ ] **Step 6: Commit** (лише з дозволу)

```bash
git add roles/topology/tasks/main.yml roles/consul/defaults/main.yml
git commit -m "feat(consul): derive datacenter scope from topology profile"
```

---

### Task 7: Глобальний scope для Patroni і HAProxy

**Files:**
- Modify: `roles/patroni/defaults/main.yml`
- Modify: `roles/haproxy/defaults/main.yml`

**Interfaces:**
- Consumes: `_topology_db_scope` з Task 6.
- Produces: `patroni_cluster_hosts` і `haproxy_backends`, які при `global`
  охоплюють усі DC.

- [ ] **Step 1: Розширити patroni_cluster_hosts**

У `roles/patroni/defaults/main.yml` замінити `patroni_cluster_hosts` на:

```yaml
# Under the stretch profile the cluster IS one across datacenters, so the peer
# list must not be filtered by the local DC.
patroni_cluster_hosts: >-
  {{ (groups['patroni'] | default([]))
     if (_topology_db_scope | default('dc')) == 'global'
     else ((groups['patroni'] | default([])
            | map('extract', hostvars)
            | selectattr('datacenter', 'defined')
            | selectattr('datacenter', '==', datacenter)
            | map(attribute='inventory_hostname') | list)
           or (groups['patroni'] | default([]))) }}
```

- [ ] **Step 2: Розширити haproxy_backends**

У `roles/haproxy/defaults/main.yml` замінити `haproxy_backends` на:

```yaml
# Two uses: gating the listeners, and sizing the RO server-template slot count.
# Under 'global' scope replica.<scope>.service.consul returns replicas from every
# datacenter, so a DC-filtered count would leave most of them without a slot.
# The RW listener needs no change: it resolves primary.<scope>.service.consul,
# which points at the real leader wherever it lives.
haproxy_backends: >-
  {{ (groups['patroni'] | default([]))
     if (_topology_db_scope | default('dc')) == 'global'
     else ((groups['patroni'] | default([])
            | map('extract', hostvars)
            | selectattr('datacenter', 'defined')
            | selectattr('datacenter', '==', datacenter)
            | map(attribute='inventory_hostname') | list)
           or (groups['patroni'] | default([]))) }}
```

`haproxy_rabbitmq_backends` **не чіпати**: RabbitMQ лишається per-DC у всіх
профілях, включно зі `stretch`.

- [ ] **Step 3: Перевірити lint і syntax-check**

Run:
```bash
yamllint . && ansible-lint
for inv in singlehost multihost failover warm-standby-2dc; do
  ansible-playbook --syntax-check -i "inventories/${inv}.example" site.yml || echo "BROKEN: ${inv}"
done
./tests/run.sh
```
Expected: чисто, усі тести `ok`.

- [ ] **Step 4: Commit** (лише з дозволу)

```bash
git add roles/patroni/defaults/main.yml roles/haproxy/defaults/main.yml
git commit -m "feat(patroni,haproxy): honour global db scope in stretch profile"
```

---

### Task 8: Увімкнення `stretch` — тайминги, синхронність, fault domains

Це таск, який робить `stretch` реальним профілем: глобальний scope уже є в ролях
(таски 6–7), лишається розширити тайминги raft, дати вибір `synchronous_mode`,
додати асерт трьох fault domains і зняти прапорець `implemented: false`.

**Files:**
- Create: `tests/fixtures/valid-stretch.yml`
- Create: `tests/fixtures/invalid-stretch-2dc.yml`
- Modify: `roles/consul/defaults/main.yml`
- Modify: `roles/consul/templates/consul.hcl.j2`
- Modify: `roles/patroni/defaults/main.yml`
- Modify: `roles/patroni/templates/patroni.yml.j2`
- Modify: `roles/topology/vars/main.yml` (`stretch.implemented: true`)
- Modify: `playbooks/validate_topology.yml` (асерт fault domains)
- Modify: `tests/cases.txt`
- Modify: `roles/patroni/README.md`, `roles/consul/README.md`

**Interfaces:**
- Consumes: `_topology_db_scope` з Task 6.
- Produces: змінні `consul_raft_multiplier`, `patroni_ttl`, `patroni_loop_wait`,
  `patroni_retry_timeout`, `patroni_synchronous_mode`.

- [ ] **Step 1: Написати фікстури stretch**

`tests/fixtures/valid-stretch.yml`:

```yaml
---
all:
  vars:
    topology_profile: stretch
    dns_upstream_servers: [10.0.0.1]
  children:
    dc1:
      vars:
        datacenter: dc1
      hosts:
        db1: {}
        mq1: {}
    dc2:
      vars:
        datacenter: dc2
      hosts:
        db2: {}
        mq2: {}
    dc3:
      vars:
        datacenter: dc3
      hosts:
        db3: {}
        mq3: {}
    patroni:
      hosts:
        db1: {}
        db2: {}
        db3: {}
    consul_server:
      hosts:
        db1: {}
        db2: {}
        db3: {}
```

`tests/fixtures/invalid-stretch-2dc.yml` — кворум лише у двох fault domains:

```yaml
---
all:
  vars:
    topology_profile: stretch
    dns_upstream_servers: [10.0.0.1]
  children:
    dc1:
      vars:
        datacenter: dc1
      hosts:
        db1: {}
        db2: {}
    dc2:
      vars:
        datacenter: dc2
      hosts:
        db3: {}
    patroni:
      hosts:
        db1: {}
        db2: {}
        db3: {}
    consul_server:
      hosts:
        db1: {}
        db2: {}
        db3: {}
```

- [ ] **Step 2: Оновити таблицю випадків**

У `tests/cases.txt` замінити рядок

```
invalid-stretch-not-implemented|2|not yet implemented
```

на

```
invalid-stretch-not-implemented|0|
```

(фікстура лишається як валідний тризонний stretch — після цього таска вона має
проходити; за бажанням перейменувати файл у `valid-stretch-minimal.yml` і
оновити рядок відповідно)

і дописати:

```
valid-stretch|0|
invalid-stretch-2dc|2|requires at least 3 datacenters
```

- [ ] **Step 3: Запустити і переконатись, що падає**

Run: `./tests/run.sh`
Expected: FAIL для `valid-stretch` і `invalid-stretch-not-implemented`
(`rc=2, expected 0` — профіль ще позначений як нереалізований).

- [ ] **Step 4: Зняти прапорець і додати асерт fault domains**

У `roles/topology/vars/main.yml` у блоці `stretch` замінити

```yaml
    # Flipped to true in the task that lands the global-scope roles.
    implemented: false
```

на

```yaml
    implemented: true
```

У `playbooks/validate_topology.yml`, поряд з рештою асертів scope:

```yaml
    - name: Validate | Stretch DCS quorum must sit in exactly three fault domains
      ansible.builtin.assert:
        that: >-
          (groups['consul_server'] | default([])
           | map('extract', hostvars)
           | map(attribute='datacenter')
           | unique | list | length) == 3
        fail_msg: >-
          Profile 'stretch' puts consul_server nodes in exactly three fault
          domains, found
          {{ groups['consul_server'] | default([]) | map('extract', hostvars) | map(attribute='datacenter') | unique | list | length }}.
          Additional datacenters may host consul agents and patroni replicas, but
          no DCS servers.
        quiet: true
      when: topology_profiles[topology_profile].dcs_scope == 'global'
```

- [ ] **Step 5: Запустити і переконатись, що проходить**

Run: `./tests/run.sh`
Expected: усі шістнадцять випадків `ok`.

- [ ] **Step 6: Додати raft_multiplier у дефолти consul**

У `roles/consul/defaults/main.yml`:

```yaml
# Consul raft timings assume a LAN. Under 'global' scope the quorum spans sites,
# so heartbeat and leader-lease windows have to widen or leadership will flap on
# a slow link. 5 is Consul's own recommendation for high-latency links; 1 is the
# LAN default. Tune down once the real inter-site RTT is measured.
consul_raft_multiplier: >-
  {{ 5 if (_topology_db_scope | default('dc')) == 'global' else 1 }}
```

- [ ] **Step 7: Відрендерити його в конфіг**

У `roles/consul/templates/consul.hcl.j2` після рядка 2 (`datacenter = "{{ consul_datacenter }}"`) додати:

```jinja
performance {
  raft_multiplier = {{ consul_raft_multiplier }}
}
```

- [ ] **Step 8: Додати тайминги і synchronous_mode у дефолти patroni**

У `roles/patroni/defaults/main.yml`:

```yaml
# Patroni DCS timings, widened under 'global' scope for the same reason as
# consul_raft_multiplier. ttl must stay above loop_wait + 2 * retry_timeout.
patroni_loop_wait: "{{ 10 if (_topology_db_scope | default('dc')) == 'global' else 10 }}"
patroni_ttl: "{{ 60 if (_topology_db_scope | default('dc')) == 'global' else 30 }}"
patroni_retry_timeout: "{{ 20 if (_topology_db_scope | default('dc')) == 'global' else 10 }}"
# Off by default: synchronous replication across sites costs a WAN round trip on
# every commit. Turning it on is the user's RPO decision — without it a failover
# to another datacenter loses the transactions that had not shipped yet.
patroni_synchronous_mode: false
```

- [ ] **Step 9: Відрендерити їх у patroni.yml**

У `roles/patroni/templates/patroni.yml.j2` рядки 29–31 наразі містять константи:

```jinja
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
```

Замінити їх (зберігаючи ту саму індентацію в 4 пробіли під `bootstrap.dcs:`) на:

```jinja
    ttl: {{ patroni_ttl }}
    loop_wait: {{ patroni_loop_wait }}
    retry_timeout: {{ patroni_retry_timeout }}
    synchronous_mode: {{ patroni_synchronous_mode | bool | lower }}
```

- [ ] **Step 10: Задокументувати нові змінні**

У `roles/consul/README.md` додати рядок таблиці змінних для `consul_raft_multiplier`,
у `roles/patroni/README.md` — для `patroni_ttl`, `patroni_loop_wait`,
`patroni_retry_timeout`, `patroni_synchronous_mode`, з поясненням, що перші три
автоматично ширші під `stretch`, а `synchronous_mode` — свідомий вибір RPO.

- [ ] **Step 11: Перевірити**

Run:
```bash
yamllint . && ansible-lint
for inv in singlehost multihost failover warm-standby-2dc; do
  ansible-playbook --syntax-check -i "inventories/${inv}.example" site.yml || echo "BROKEN: ${inv}"
done
./tests/run.sh
```
Expected: чисто, усі шістнадцять тестів `ok`.

- [ ] **Step 12: Commit** (лише з дозволу)

```bash
git add roles/consul roles/patroni roles/topology/vars/main.yml \
        playbooks/validate_topology.yml tests
git commit -m "feat(stretch): enable the stretch profile with widened raft timings"
```

---

### Task 9: Prepared queries на кожному Consul-кластері

Дефект, який виявила формалізація: `roles/consul/tasks/prepared_queries.yml`
виконується один раз глобально (`run_once` у самих тасках плюс `run_once` на
`include_role` у `playbooks/consul.yml`) з делегуванням на
`groups['consul_server'][0]`. При `warm_standby` кожен DC має **свій ізольований**
Consul, тож другий DC ніколи не отримає запити `webitel-api` і
`webitel-messages-bot`, і nginx там резолвитиме `webitel-api.query.consul` у
NXDOMAIN (`roles/nginx/tasks/configure.yml:25`).

**Files:**
- Create: `roles/consul/tasks/prepared_queries_one.yml`
- Modify: `roles/consul/tasks/prepared_queries.yml`

**Interfaces:**
- Consumes: `_topology_db_scope` з Task 6.
- Produces: `prepared_queries.yml` стає диспетчером; `prepared_queries_one.yml`
  очікує змінну `_consul_target` — inventory_hostname сервера, на який делегувати.

- [ ] **Step 1: Винести наявну логіку в один-кластер-файл**

`roles/consul/tasks/prepared_queries_one.yml`:

```yaml
---
# Creates the prepared queries on ONE Consul cluster, reached through
# _consul_target. The caller loops over one server per cluster.
- name: Get existing Consul prepared queries
  ansible.builtin.uri:
    url: http://127.0.0.1:8500/v1/query
    method: GET
    return_content: true
  register: _consul_queries
  delegate_to: "{{ _consul_target }}"

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
    label: "{{ _consul_target }}/{{ item.name }}"
  when: item.name not in (_consul_queries.json | map(attribute='Name') | list)
  delegate_to: "{{ _consul_target }}"
```

- [ ] **Step 2: Перетворити prepared_queries.yml на диспетчер**

`roles/consul/tasks/prepared_queries.yml` цілком замінити на:

```yaml
---
# Aliases DNS-unfriendly service names (go.webitel.api) to query.consul names.
# Prepared queries are per Consul cluster, and under the 'dc' scope every
# datacenter runs its own isolated cluster — so this has to run once per cluster,
# not once globally, or nginx in the other datacenters gets NXDOMAIN.
- name: Resolve one consul_server per Consul cluster
  ansible.builtin.set_fact:
    _consul_query_targets: >-
      {{ [(groups['consul_server'] | default([]))[0]]
         if (_topology_db_scope | default('dc')) == 'global'
         else ((groups['consul_server'] | default([])
                | map('extract', hostvars)
                | groupby('datacenter')
                | map(attribute='1') | map('first')
                | map(attribute='inventory_hostname') | list)) }}

- name: Create prepared queries on every Consul cluster
  ansible.builtin.include_tasks: prepared_queries_one.yml
  loop: "{{ _consul_query_targets }}"
  loop_control:
    loop_var: _consul_target
```

- [ ] **Step 3: Перевірити, що цілі рахуються правильно**

Run:
```bash
cat > /tmp/probe-targets.yml <<'EOF'
---
- name: Probe query targets
  hosts: localhost
  gather_facts: false
  tasks:
    - name: Show one consul_server per datacenter
      ansible.builtin.debug:
        msg: >-
          {{ groups['consul_server'] | default([])
             | map('extract', hostvars)
             | groupby('datacenter')
             | map(attribute='1') | map('first')
             | map(attribute='inventory_hostname') | list }}
EOF
ansible-playbook -i tests/fixtures/valid-warm-standby.yml /tmp/probe-targets.yml
rm /tmp/probe-targets.yml
```
Expected: рівно два хости — по одному з `dc_a` і `dc_b`.

- [ ] **Step 4: Перевірити lint і syntax-check**

Run:
```bash
yamllint . && ansible-lint
for inv in singlehost multihost failover warm-standby-2dc; do
  ansible-playbook --syntax-check -i "inventories/${inv}.example" site.yml || echo "BROKEN: ${inv}"
done
./tests/run.sh
```
Expected: чисто.

- [ ] **Step 5: Commit** (лише з дозволу)

```bash
git add roles/consul/tasks
git commit -m "fix(consul): create prepared queries on every Consul cluster"
```

---

### Task 10: Приклади інвентарів, CI, README

**Files:**
- Modify: `inventories/singlehost.example/group_vars/all/main.yml`
- Modify: `inventories/multihost.example/group_vars/all/main.yml`
- Modify: `inventories/failover.example/group_vars/all/main.yml`
- Modify: `inventories/warm-standby-2dc.example/group_vars/all/main.yml`
- Modify: `.github/workflows/reviewdog.yml`
- Modify: `README.md`

**Interfaces:**
- Consumes: усе попереднє.
- Produces: жодних нових змінних.

- [ ] **Step 1: Оголосити профіль у кожному прикладі**

Додати першим значущим рядком у кожен
`inventories/<name>.example/group_vars/all/main.yml`:

- `inventories/singlehost.example/...`:
  ```yaml
  # Supported deployment shape. See README > Deployment profiles.
  topology_profile: singlehost
  ```
- `inventories/multihost.example/...`:
  ```yaml
  topology_profile: multihost
  ```
- `inventories/failover.example/...`:
  ```yaml
  topology_profile: failover
  ```
- `inventories/warm-standby-2dc.example/...`:
  ```yaml
  topology_profile: warm_standby
  # Which datacenter bootstraps the primary Patroni cluster. The others come up
  # as standby clusters streaming from it.
  primary_datacenter: dc_a
  ```

- [ ] **Step 2: Перевірити, що приклади проходять валідацію**

Run:
```bash
for inv in singlehost multihost failover warm-standby-2dc; do
  echo "--- ${inv}"
  ansible-playbook -i "inventories/${inv}.example" playbooks/validate_topology.yml
done
```
Expected: усі чотири — rc=0.

Якщо `warm-standby-2dc` падає — це очікуваний і корисний сигнал: приклад ще не
має `standby_cluster` (див. план `2026-06-17-patroni-warm-standby-2dc.md`).
Валідація дивиться лише на форму інвентаря, тож із `primary_datacenter` вона має
проходити. Якщо падає щось інше — розібратись і виправити приклад, а не асерт.

- [ ] **Step 3: Додати прогін тестів у CI**

У `.github/workflows/reviewdog.yml`, у джобу `validate`, після кроку `ansible-lint`
і перед syntax-check'ами:

```yaml
      - name: Topology validation tests
        run: ./tests/run.sh
```

Після чотирьох наявних syntax-check-кроків додати п'ятий:

```yaml
      - name: Validate example inventories against their profiles
        run: |
          for inv in singlehost multihost failover warm-standby-2dc; do
            ansible-playbook -i "inventories/${inv}.example" playbooks/validate_topology.yml
          done
```

- [ ] **Step 4: Замінити таблицю схем у README**

У `README.md` у секції `## HA deployment` замінити абзац «Webitel 26.4 supports
three HA deployment schemes» і таблицю `### Schemes` на:

```markdown
## Deployment profiles

Every inventory declares what it is via `topology_profile` in
`group_vars/all/main.yml`. Preflight refuses to run when the inventory does not
match the declared profile, so unsupported shapes fail before the first package
is installed.

| `topology_profile` | Datacenters | PostgreSQL | Consul | RabbitMQ / Nomad | Promotion |
|---|---|---|---|---|---|
| `singlehost` | 1 (one host) | standalone | 1 server, loopback | single | — |
| `multihost` | 1 | standalone | 1 server | single | — |
| `failover` | 1 | one Patroni cluster | 1 cluster, 3+, odd | cluster | Patroni, within the DC |
| `warm_standby` | 2+ | primary cluster + N standby clusters | isolated cluster per DC | per DC | external controller |
| `stretch` | 3+ | one cluster across all DCs | one raft over three fault domains | per DC | Patroni, automatic |

Host and datacenter counts are not part of the profile: `warm_standby` is N
datacenters, not two. At three datacenters both `warm_standby` and `stretch` are
available — the profile name is the choice, it is never inferred.

`stretch` is active/passive: traffic is served by the datacenter holding the
database leader. It widens Consul and Patroni raft timings automatically; set
`patroni_synchronous_mode: true` if a cross-DC failover must not lose
transactions, at the cost of a WAN round trip per commit.

Design rationale: `docs/superpowers/specs/2026-09-10-topology-profiles-design.md`.
```

Далі в README залишити наявні підсекції `#### Failover (1-DC, single cluster)` і
`#### Warm standby (2-DC, per-DC clusters)`, але прибрати з них рядок
«cross-DC replication ... is phase 3, not yet implemented» лише тоді, коли
`standby_cluster` реально з'явиться — у межах цього плану цей рядок лишається.

- [ ] **Step 5: Фінальна перевірка**

Run:
```bash
yamllint . && ansible-lint
./tests/run.sh
for inv in singlehost multihost failover warm-standby-2dc; do
  ansible-playbook --syntax-check -i "inventories/${inv}.example" site.yml
  ansible-playbook -i "inventories/${inv}.example" playbooks/validate_topology.yml
done
```
Expected: усе зелене.

- [ ] **Step 6: Commit** (лише з дозволу)

```bash
git add inventories .github/workflows/reviewdog.yml README.md
git commit -m "docs: declare topology profiles in examples, README and CI"
```

---

## Порядок і контрольні точки

Таски 1–5 дають працюючий гейт над чотирма наявними профілями (`stretch`
відхиляється як нереалізований). Таски 6–8 додають `stretch`. Таск 9 — незалежний
багфікс, який можна робити будь-коли після Task 6. Таск 10 закриває документацію.

Після Task 5 і після Task 8 система у консистентному стані — це природні місця,
щоб зупинитись і показати результат.

## Поза планом

- Реалізація `standby_cluster` для `warm_standby` — окремий план
  `docs/superpowers/plans/2026-06-17-patroni-warm-standby-2dc.md`.
- Guard роль-`patroni`-проти-відкоту-promote (запит Patroni REST перед конфігом).
  Свідомо відкладено: доки `standby_cluster` не реалізований, guard-у нема чого
  захищати. Він має увійти в план `standby_cluster` тим самим коммітом, що й
  сам блок — інакше з'явиться вікно, у якому re-run Ansible відкочує promote,
  зроблений зовнішньою утилітою.
- Локальність читань у `stretch` (prepared query з `Near` або фільтр по node-meta).
- Рендер дефолтів ролей (`consul_datacenter`, `patroni_cluster_hosts`,
  `haproxy_backends`) фікстурами не покривається: харнес працює на `localhost`
  без фактів, а ці вирази обчислюються під час прогону ролі на реальному хості.
  Їх гейтять `yamllint`/`ansible-lint`/`--syntax-check` і справжній прогін на
  OrbStack чи staging.
