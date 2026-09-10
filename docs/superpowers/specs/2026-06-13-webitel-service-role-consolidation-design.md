# webitel_service — одна data-driven роль замість ролі-на-сервіс

- **Дата:** 2026-06-13
- **Статус:** дизайн узгоджено, реалізація попереду
- **Автор:** Yurii Kirychuk

## Проблема

Ролі `webitel_engine`, `webitel_logger`, `webitel_storage`, `webitel_cases`,
`webitel_messages`, `webitel_call_center`, `webitel_flow_manager`,
`webitel_media_exporter` — **байт-у-байт однакові за логікою**. Кожна робить рівно
три кроки:

1. `apt` install `{{ *_package }}`
2. `lineinfile` цикл по `(*_env_defaults | combine(*_env_extra))` у `*_env_file`,
   `notify` рестарт
3. `systemd_service: enabled + started`

Handler у всіх ідентичний (`restart <unit>`). Відрізняються **лише дані**: ім'я
пакета, unit, шлях до env-файлу, словник `env_defaults`. Тобто 8 ролей ×
(tasks + handlers + defaults) — це 8 копій одного коду, де унікальним є тільки
`defaults/main.yml`.

Два сервіси стоять окремо:

- **`webitel_core`** — ставить 3 юніти (`webitel-api`, `webitel-app`,
  `webitel-uac`), env через `lineinfile` не чіпає, рестарт делегований у
  `webitel_common` (handler «restart webitel core services»).
- **`webitel_common`** — спільна підготовка хостів (GPG/репо/залежності), не
  сервіс. Лишається як є.

## Рішення: одна роль `webitel_service` + каталог per-service

Уся логіка install/env/systemd живе в **одній** ролі `webitel_service`,
параметризованій одним входом `webitel_service_name`. Дані кожного сервісу
(package, units, env_file, env) живуть у **per-service vars-файлах**. Особливості
конкретного сервісу (зараз — лише `core`) виносяться в **опціональний
per-service include-хук**, а не в `when:`-умови всередині ядра ролі.

`webitel_core` теж складається в цей механізм — це не виняток, а запис каталогу з
`units: [webitel-api, webitel-app, webitel-uac]` і `manage_env: false`. Окрема
роль `webitel_core` видаляється; делегований рестарт замінюється generic-handler.

### Чому не «тонкі обгортки» і не «цикл у плейбуку»

- **Тонкі ролі-обгортки** (8 папок по `include_role: webitel_service` + свій
  `defaults`) лишають церемонію без виграшу: теги `webitel_X_*` відтворюються
  динамічно, окремі README не виправдовують 8 папок.
- **Цикл прямо в `webitel.yml`** розмазує логіку між плейбуком і vars і ламає
  звичний `roles:`-інтерфейс. Гірша читабельність.

Одна роль = одне місце з логікою + одне місце з даними.

### Запобіжник від дрейфу (головне архітектурне рішення)

Головний ризик data-driven ролі — сповзання в `when: name == 'x'`-суп при появі
особливостей. Тому ядро ролі обробляє **лише уніфіковану форму**, а будь-яка
специфіка сервісу підключається опціональним файлом-хуком:

```yaml
- name: Service-specific tasks
  ansible.builtin.include_tasks: "{{ role_path }}/tasks/services/{{ webitel_service_name }}.yml"
  when: (role_path ~ '/tasks/services/' ~ webitel_service_name ~ '.yml') is exists
```

Так дублювання повертається рівно туди, де воно виправдане — на справді унікальну
логіку — і ніде більше. Ядро ролі лишається чистим.

## Структура `webitel_service`

```
roles/webitel_service/
  defaults/main.yml          # дефолти форми сервісу (manage_env, units тощо)
  vars/services/<name>.yml    # per-service дані: package/units/env_file/env
  tasks/main.yml             # ядро: load spec → install → env → enable → hooks
  tasks/services/<name>.yml   # ОПЦІЙНО: специфіка сервісу (поки лише core не треба)
  handlers/main.yml          # generic restart по units
  README.md                  # інтерфейс ролі
```

### Модель даних

Per-service файл `vars/services/<name>.yml` тримає рівно те, що зараз у
`defaults/main.yml` сервісу, у вигляді одного дикта:

```yaml
# vars/services/engine.yml
webitel_service_spec:
  package: webitel-engine
  units: [webitel-engine]
  env_file: /etc/default/engine
  manage_env: true
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

```yaml
# vars/services/core.yml — особливий, але через дані, не через код
webitel_service_spec:
  package: webitel-core
  units: [webitel-api, webitel-app, webitel-uac]
  manage_env: false
```

Per-service файли (а не один дикт-моноліт) обрано свідомо: `grep -r engine
roles/webitel_service/vars` усе ще знаходить «дім» сервісу — discoverability не
страждає.

### Дефолти форми (`defaults/main.yml`)

Щоб типовий сервіс описувався мінімально, ядро застосовує дефолти поверх spec:

- `units` → `[ webitel_service_spec.package ]`, якщо не задано
- `manage_env` → `true`
- `env_file` → `/etc/default/{{ webitel_service_name }}`, якщо не задано
- `env` → `{}`

Реалізується через `webitel_service_spec` із дефолтним дефолт-диктом, який
`combine`-иться з тим, що в `vars/services/<name>.yml`.

### `tasks/main.yml` (ядро)

```
1. include_vars: vars/services/{{ webitel_service_name }}.yml
2. apt install spec.package                              [tag: install]
3. include_tasks services/<name>.yml  (if exists)        [hook]
4. if spec.manage_env:
     lineinfile loop over (spec.env | combine(env_extra))  [tag: configure]
     notify restart
5. systemd_service enabled+started loop over spec.units    [tag: configure]
```

**Теги.** Темплейтовані теги з host-vars у Ansible ненадійні (теги обробляються на
парсингу). Тому використовуємо **фазові теги `install` / `configure`** всередині
ролі, а per-service тег `webitel_<name>` навішуємо статично на рівні include в
плейбуку:

```yaml
roles:
  - role: webitel_service
    webitel_service_name: engine
    tags: [webitel_engine]
```

Скоупінг:
- `--tags configure` — фаза configure для всіх сервісів
- `--limit webitel_engine --tags install` — install лише engine (групи від
  constructed-плагіна збережено)
- `--tags webitel_engine` — увесь сервіс engine

### Override env

Замість 8 окремих `webitel_X_env_extra` — один механізм:
`webitel_service_env_extra` (дикт), що задається в group_vars/host_vars хоста.
Оскільки кожна сервіс-група = один сервіс, простий дикт достатній:

```yaml
# group_vars/webitel_engine/main.yml
webitel_service_env_extra:
  SOME_KEY: value
```

Фінальний env = `spec.env | combine(webitel_service_env_extra | default({}))`.

### Handler

Generic, рестартить кожен unit зі `spec.units`:

```yaml
- name: Restart webitel service
  ansible.builtin.systemd_service:
    name: "{{ item }}"
    state: restarted
    daemon_reload: true
  loop: "{{ webitel_service_spec.units }}"
  listen: restart webitel service
```

(`notify` у tasks використовує спільний `listen`-рядок «restart webitel service».)

## Зміни в плейбуку `webitel.yml`

Per-service плеї лишаються (явні `hosts: webitel_X` — групи від constructed-плагіна
не змінюються), але тіло кожного — 3 рядки:

```yaml
- name: Webitel engine
  hosts: webitel_engine
  become: true
  any_errors_fatal: true
  roles:
    - { role: webitel_service, webitel_service_name: engine, tags: [webitel_engine] }
```

Плей `webitel_core` так само переходить на `webitel_service` з
`webitel_service_name: core`. Спільний плей `webitel_common` лишається першим
без змін.

## Видалення

Прибираються папки ролей:
`webitel_core`, `webitel_engine`, `webitel_call_center`, `webitel_flow_manager`,
`webitel_storage`, `webitel_messages`, `webitel_logger`, `webitel_cases`,
`webitel_media_exporter`.

Лишаються: `webitel_service` (нова), `webitel_common` (без змін).

`playbooks/vars/known_services.yml` не змінюється — імена груп/сервісів ті самі.

## ОНОВЛЕННЯ (2026-06-15): `webitel_common` розчинено в core

Після реалізації користувач уточнив три пакетні факти, що скасували рішення
нижче («handler лишається»):

1. `/etc/default/webitel` читають **лише** core-юніти (api/app/uac).
2. Пакет `webitel-core` потрібен **лише** на core-хостах.
3. `WBTL_COOKIE_KEYS` споживає **лише** `webitel-api`.

Тому `webitel_common` (install `webitel-core` + configure `/etc/default/webitel`
на всіх хостах) **видалено повністю**, а його відповідальності складено в
`vars/services/core.yml`:
- `manage_env: true`, `env_file: /etc/default/webitel`, env = колишні
  `webitel_common_env_defaults` (9 ключів, байт-у-байт).
- Похідні `webitel_sip_address` і `webitel_cookie_keys` (lookup по
  `webitel_cookie_seed`) перенесено в той самий файл (`# noqa: var-naming`).
- Core тепер звичайний `webitel_service`-запис без спецкейсів; рестарт — через
  generic-handler.
- Перший плей `Webitel common configuration` прибрано з `webitel.yml` (лишився
  `import_playbook: topology.yml` першим, як у решти домен-плейбуків).

Розділ нижче лишено для історії — він **більше не актуальний**.

## ~~Делегований рестарт core (handler у `webitel_common` ЛИШАЄТЬСЯ)~~ — СКАСОВАНО

**Перевірено при реалізації — handler не видаляємо.** `webitel_common` рендерить
**спільний** `/etc/default/webitel` на кожному webitel-хості (`configure.yml`
робить `notify: restart webitel core services`). Core-юніти (api/app/uac)
споживають саме цей файл, тому при його зміні їх треба рестартити — handler
guard-иться на `groups['webitel_core']`. Це відношення між `webitel_common` і
core-юнітами, **незалежне** від того, окрема роль core чи через `webitel_service`.

Новий `webitel_service` для core має `manage_env: false` — він не чіпає жодного
env-файлу, тож конфлікту немає. Generic-handler `webitel_service` рестартить core
лише на першій інсталяції/зміні власних тасків ролі; рестарт через зміну спільного
env лишається за handler-ом `webitel_common`. Обидва безпечні (ідемпотентні).

## Тестування

- `yamllint` + `ansible-lint` + `ansible-playbook --syntax-check` — зелені.
- `--list-tags` на `webitel.yml` — переконатися, що присутні фазові теги
  `install`/`configure` і per-service теги `webitel_<name>`.
- Функціональний прогін в OrbStack — за користувачем (env-файли пакетів
  редагуються на місці, як і зараз; lineinfile падає голосно, якщо файл відсутній).

## Ризики й чесна оцінка

- **Дрейф у `when:`** — закрито include-хуком; ядро не отримує сервіс-специфіки.
- **Discoverability** — пом'якшено per-service vars-файлами; теги динамічні, але
  стабільні за іменуванням.
- **Ергономіка override** — `webitel_service_env_extra` трохи менш звичний за
  `webitel_engine_env_extra`, але single-сервіс-на-групу робить це безболісним.

Оцінка підходу для поточного стану (8 однакових сервісів + 1 через дані): висока,
за умови що include-хук і per-service vars закладені з самого початку.
