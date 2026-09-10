# postgres_common — спільний субстрат для ролей postgres і patroni

- **Дата:** 2026-06-13
- **Статус:** реалізовано (yamllint + ansible-lint + syntax-check зелені; функціональний прогін в OrbStack — за користувачем)
- **Автор:** Yurii Kirychuk

## Проблема

Ролі `postgres` (standalone) і `patroni` (HA) дублюють дві значні частини:

1. **Встановлення** (`install.yml`) — GPG-ключі PGDG+TimescaleDB, репозиторії
   (`deb822_repository`), `apt`-встановлення пакетів. Майже дослівна копія.
2. **Бутстрап БД** — `postgres/database.yml` vs `patroni/bootstrap_db.yml`:
   create app user → create `webitel` db → restore schema files. Логіка та сама,
   відрізняється лише спосіб підключення.

Також дублюються `defaults` (app_user, app_password, db, schema_files,
keyring-шляхи, major, частина списку пакетів).

Окрім дублювання, є дві приховані розбіжності:

- `patroni` ставив `webitel-postgresql-migrations` **без** суфікса мажора, тоді як
  правильна назва — `webitel-postgresql-migrations-{N}`. Це баг.
- Fix прав на каталог `/usr/share/postgresql/{N}/webitel` (пакет створює його з
  режимом 644 без `+x`, у нього не зайти під `postgres`) є лише в `postgres`.
  `patroni` рестворить ті самі файли з того ж пакета — тобто це латентний баг
  patroni.

## Рішення: спільний субстрат-роль

Залишаємо **дві ролі** (`postgres`, `patroni`) і виносимо спільне у нову роль
`postgres_common`. Інвентар не змінюється взагалі: групи `postgres`/`patroni`,
`playbooks/preflight.yml`, `patroni_cluster_hosts`, `playbooks/database.yml` —
без змін. Це головна перевага підходу проти злиття в одну роль.

Спільне підключається через `ansible.builtin.include_role` у потрібних точках
кожної ролі (**не** через `meta/main.yml dependencies`, бо `bootstrap` має йти
**після** `configure`, а dependencies виконуються безумовно й до тасків ролі).

### Структура `postgres_common`

```
roles/postgres_common/
  defaults/main.yml      # єдине джерело правди для спільних змінних
  tasks/install.yml      # GPG + repo + apt базових пакетів
  tasks/configure.yml    # бутстрап БД: create user/db, fix прав, restore
  README.md              # документує інтерфейс ролі
```

#### `tasks/install.yml`

Переноситься дослівно те, що зараз дублюється:

- Download + dearmor PGDG GPG key
- Download + dearmor TimescaleDB GPG key
- Add PGDG repository (`deb822_repository`)
- Add TimescaleDB repository (`deb822_repository`)
- `apt` встановлення **базового** списку пакетів (`pg_base_packages`)

Базовий список пакетів:

```
postgresql-{N}
timescaledb-2-postgresql-{N}
webitel-postgresql-{N}
webitel-postgresql-migrations-{N}
```

Роль-специфічні пакети встановлює сама роль-споживач (окремим `apt`-таском або
розширюючи список), бо вони не належать субстрату:

- `postgres` додає: `timescaledb-tools`
- `patroni` додає: `patroni`, `python3-consul`

#### `tasks/configure.yml`

Спільний бутстрап БД (за конвенцією роль називає цей крок `configure`),
параметризований способом підключення:

- Create application user (`role_attr_flags: SUPERUSER`)
- Create `webitel` database (з owner)
- Ensure SQL directory traversable — chmod 0755 на
  `/usr/share/postgresql/{N}/webitel` (раніше лише в postgres; тепер спільний —
  лагодить латентний баг patroni)
- Restore schema + data (`postgresql_db: state=restore`), `when: <db> is changed`

Інтерфейс підключення (передається через `vars:` на `include_role`):

| Змінна | standalone (`postgres`) | HA (`patroni`) |
|---|---|---|
| `postgres_common_login_host` | не задано → peer (`become_user: postgres`) | `127.0.0.1` |
| `postgres_common_login_user` | не задано | `{{ patroni_superuser_user }}` |
| `postgres_common_login_password` | не задано | `{{ patroni_superuser_password }}` |

Коли `postgres_common_login_host` порожній — модулі `community.postgresql.*`
працюють через локальний сокет під `become_user: postgres` (peer-auth), як зараз
у standalone. У тасках це реалізується через `| default(omit, true)`, тож порожнє
значення = параметр не передається модулю.

#### `defaults/main.yml` (інтерфейс ролі)

Джерело правди для спільних змінних. Імена з префіксом `postgres_common_` —
вимога `ansible-lint` (production profile, правило `var-naming[no-role-prefix]`:
дефолти ролі мусять мати префікс імені ролі). Споживачі передають значення через
`vars:` на `include_role`.

```yaml
# pg_major НЕ перевизначаємо тут — це факт із preflight set_fact (15|18),
# доступний глобально; шаблони нижче читають його напряму.
postgres_common_db: webitel
postgres_common_app_user: opensips
postgres_common_app_password: webitel
postgres_common_schema_files:
  - "/usr/share/postgresql/{{ pg_major }}/webitel/webitel-db-schema.sql"
  - "/usr/share/postgresql/{{ pg_major }}/webitel/webitel-db-data.sql"
postgres_common_base_packages: [...]   # базовий список вище
postgres_common_pgdg_keyring: /usr/share/keyrings/postgresql.gpg
postgres_common_timescale_keyring: /usr/share/keyrings/timescaledb.gpg
# connection (порожні дефолти → peer)
postgres_common_login_host: ""
postgres_common_login_user: ""
postgres_common_login_password: ""
```

**Важливий нюанс scope:** `include_role` НЕ експонує дефолти включеної ролі в
зовнішній scope, а дефолти ролі завантажуються незалежно від `--tags`. Тому
змінні, які читаються **поза** `postgres_common` у тег-ізольованих блоках,
лишаються в ролях-споживачах і передаються в common:

- `patroni_app_user` — лишається в `patroni/defaults` (читається в `patroni.yml.j2`,
  pg_hba), передається як `postgres_common_app_user`.
- `postgres_db`, `postgres_helper_sql` — лишаються в `postgres/defaults`
  (`postgres_db` читається в helper-cron), `postgres_db` передається як
  `postgres_common_db`.

Решта (`*_app_password`, `*_schema_files`, `*_packages`, keyrings, `*_db` для
patroni, `*_app_user` для postgres) видаляється з ролей — використовуються лише
всередині common.

**Міграція:** інвентарні оверайди `postgres_app_*` / `patroni_app_password` /
`patroni_db` / `patroni_schema_files` треба перейменувати на `postgres_common_*`.
У прикладах інвентарів таких оверайдів немає (лише `patroni_priority`,
`patroni_allow_multidc`) — міграція стосується лише кастомних інвентарів
користувача.

### Роль `postgres` (тонка, standalone)

`tasks/main.yml`:

1. `include_role: postgres_common, tasks_from: install` (+ власний `apt` для
   `timescaledb-tools`, + `timescaledb-tune`)
2. `configure.yml` — **без змін** (listen_addresses, max_connections, pg_hba,
   керування юнітом `postgresql@{N}-main`, старт/очікування готовності)
3. `include_role: postgres_common, tasks_from: configure` (peer-режим — без
   `pg_login_*`), + helper-cron

`handlers/main.yml` (restart/reload postgresql) — лишається в `postgres`.

### Роль `patroni` (тонка, HA)

`tasks/main.yml`:

1. `include_role: postgres_common, tasks_from: install` (+ власний `apt` для
   `patroni`, `python3-consul`; + disable native `postgresql` unit; + drop
   auto-created cluster `pg_dropcluster`)
2. `configure.yml` — **без змін** (рендер `patroni.yml.j2`, enable/start `patroni`)
3. leader-gate (`when: inventory_hostname == (patroni_cluster_hosts | first)` +
   очікування `/leader` REST endpoint), що обгортає
   `include_role: postgres_common, tasks_from: configure` з
   `pg_login_host=127.0.0.1` та superuser-кредами

`handlers/main.yml` (restart patroni) — лишається в `patroni`.
`templates/patroni.yml.j2` — лишається в `patroni`.

## Що НЕ переноситься в субстрат (лишається в ролях)

- **standalone-конфігурація**: `listen_addresses`, `max_connections`, `pg_hba`,
  `timescaledb-tune`, керування юнітом `postgresql@` — специфічне для постгреса,
  що керується напряму. Під Patroni ці параметри живуть у `patroni.yml`.
- **patroni-конфігурація**: `patroni.yml.j2`, disable unit, drop cluster,
  leader-gate.
- **хендлери** — повністю різні набори (postgresql vs patroni).
- **helper-cron** — лише standalone.

## Зачеплені файли

- **Нове:** `roles/postgres_common/{defaults,tasks,README.md}`
- **Змінюється:** `roles/postgres/tasks/{main,install,configure,database}.yml`,
  `roles/postgres/defaults/main.yml` (видалення перенесеного);
  `roles/patroni/tasks/{main,install,configure,bootstrap_db}.yml`,
  `roles/patroni/defaults/main.yml` (видалення перенесеного)
- **Без змін:** `playbooks/database.yml`, `playbooks/preflight.yml`, інвентарі,
  inventory-групи `postgres`/`patroni`

## Тестування / приймання

- `ansible-lint` чистий на нових/змінених ролях.
- Standalone-прогін (`hosts: postgres`) у тестовому середовищі: пакети стоять, БД
  `webitel` створена, схема залита, helper-cron на місці — поведінка ідентична
  до рефакторингу.
- Patroni-прогін (`hosts: patroni`, `serial: 1`): кластер піднявся, лідер
  забутстрапив `webitel`, SQL-каталог traversable (перевірка fix-у прав),
  реплікація працює.
- Перевірити, що `webitel-postgresql-migrations-{N}` (з суфіксом) ставиться на
  обох типах хостів.

## Відкритих питань немає
