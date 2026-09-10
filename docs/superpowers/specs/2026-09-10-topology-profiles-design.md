# Профілі топології розгортання

**Дата:** 2026-09-10
**Статус:** дизайн узгоджено, план не написано

## Проблема / мотивація

Плейбук виводить топологію з інвентаря, і це працює — але **множина того, що
можна запустити, значно ширша за множину того, що ми підтримуємо**.

1. **Гейти є, але вони незалежні.** `playbooks/preflight.yml` уже обмежує
   multi-DC чотирма булевими: `consul_allow_multidc`, `patroni_allow_multidc`,
   `nomad_allow_multidc`, `rabbitmq_allow_stretch`. Кожен вимикається окремо, тож
   з них конструюється кілька десятків комбінацій, з яких протестовані одиниці.

2. **README обіцяє три схеми, яких код не знає.** «Failover», «Warm standby»,
   «3-DC stretch» — це слова в таблиці README, а не сутності в коді. Ніщо не
   заважає зібрати інвентар, який не є жодною з них.

3. **Немає імені для контракту.** Коли користувач питає «а так можна?», відповідь
   зараз виводиться з читання чотирьох асертів, а не з одного оголошення.

Рішення — **оголошуваний іменований профіль + жорсткий гейт**: інвентар заявляє,
чим він є; preflight звіряє заявлене з похідною реальністю і падає при
розбіжності або невідомому імені.

## Межа відповідальності: Ansible vs Nomad

Це рішення передує матриці, бо визначає, що взагалі може бути в профілі.

**Ansible володіє формою субстрату. Зовнішній контролер володіє станом.**

Перемикання DC виконує Nomad (джоби) під керуванням зовнішньої утиліти, не
Ansible. Звідси:

- `primary_datacenter` в інвентарі — це **тільки початковий стан на порожньому
  кластері**, не джерело істини про поточного лідера.
- Роль `patroni` **не має права торкатися `standby_cluster` на вже існуючому
  кластері**. Перед конфігуруванням — запит до Patroni REST; якщо кластер уже
  ініціалізований, блок `standby_cluster` не переписується. Без цього guard-а
  повторний прогін Ansible відкотить promote, зроблений утилітою.
- Вісь «автоматичний vs ручний promote» **не є параметром профілю Ansible**. Вона
  описує поведінку системи, а не форму, яку будує плейбук.

Наслідок для app-рівня: окремого перемикача «cold DC» не потрібно. Ansible
провіжнить усі DC однаково, а чи запущені юніти — вирішує Nomad там, де він є
(`nomad_managed` уже так поводиться: `roles/webitel_service/tasks/main.yml`
не робить `enabled`/`started`, хендлери не рестартують).

## Матриця профілів

`topology_profile` оголошується в `group_vars/all/main.yml`. Значення — рівно одне
з п'яти; будь-яке інше = відмова preflight.

| `topology_profile` | DC | PostgreSQL | Consul | RabbitMQ / Nomad | Promote |
|---|---|---|---|---|---|
| `singlehost` | 1 | standalone | 1 сервер, на loopback | single | — |
| `multihost` | 1 | standalone | 1 сервер | single | — |
| `failover` | 1 | 1 patroni-кластер | 1 кластер, ≥3, непарний | кластер | Patroni, у межах DC |
| `warm_standby` | ≥2 | primary-кластер + N standby-кластерів | ізольований кластер на кожен DC | на кожен DC | зовнішня утиліта |
| `stretch` | ≥3 | **один** кластер на всі DC | **один** raft, сервери в 3 fault domains | на кожен DC | Patroni, автоматично |

**К-ть хостів і к-ть DC не входять у профіль.** `warm_standby` — це N датацентрів,
не два. `stretch` вимагає ≥3 лише тому, що raft потребує трьох fault domains.

**Профіль не виводиться з к-ті DC.** При трьох DC доступні обидва варіанти —
три незалежні кластери з ручним промоутом (`warm_standby`) або один розтягнутий
(`stretch`). Це вибір користувача за RPO/RTO, тому він оголошується явно.

### singlehost

Один хост, усе локально. `postgres` standalone, RabbitMQ одиночний, один
`consul_server` на `127.0.0.1` (`consul_dns_forward` вимкнений). Nomad відсутній.

### multihost

N хостів, один DC, без HA бази: `postgres` standalone на одному хості, один
`consul_server`. Покриває й випадок «два DC по одному хосту» — але тоді це два
окремі інвентарі, бо без реплікації між ними немає спільної системи
(див. «Поза матрицею»).

**Consul присутній у кожному профілі**, включно з `singlehost`. Сервіси
резолвлять залежності через нього, і поточний асерт «кожен DC має ≥1
`consul_server`» безумовний. Профіль керує тільки тим, чи це один сервер, чи
кластер, і чи він один на DC, чи один на всю інсталяцію.

### failover

Один DC, повний HA-стек: patroni-кластер, Consul-кластер (≥3, непарний), кластери
RabbitMQ і Nomad. Patroni робить автоматичний failover у межах DC. Це поточний
`inventories/failover.example`.

### warm_standby

N ≥ 2 датацентрів. Кожен DC — **ізольований** Consul (`consul_datacenter =
datacenter`, `retry_join` тільки локальні, без `retry_join_wan`) і власний
Patroni-кластер. Один DC (`primary_datacenter`) тримає primary-кластер; решта
піднімають Patroni як `standby_cluster`, що стрімить з нього.

Джерело реплікації — **нативний multi-host Patroni без haproxy**:
`standby_cluster.host` = кома-список IP усіх patroni-нод primary-DC, `port: 5432`.
Patroni додає `target_session_attrs=read-write` у `primary_conninfo`, тож libpq
тримається справжнього лідера primary і слідкує за failover там.

Реплікація асинхронна; при сильному відставанні приймаємо rebuild standby
(replication slot свідомо не тримаємо).

### stretch

N ≥ 3 датацентрів, **один** Patroni-кластер і **один** Consul raft, чиї сервери
рознесені рівно по трьох fault domains. Втрата цілого DC не ламає кворум, тож
promote робить сам Patroni — зовнішня утиліта не потрібна.

**Active/passive:** трафік обслуговує тільки той DC, де лідер БД; інші два тримають
репліки й кворум. Записи завжди локальні відносно активного DC; WAN платить лише
за реплікацію та raft-heartbeat.

При ≤2 DC профіль заборонений асертом: два fault domains кворуму не дають, і
розтягнутий кластер там купує латентність, не даючи автоматичного failover.

**Понад три DC.** Кворумні члени (Consul-сервери) живуть рівно у трьох fault
domains; четвертий і наступні DC входять лише як Consul-агенти й patroni-репліки,
без серверів DCS. Інакше кворум розмивається по лінках, кожен з яких може впасти.

## Механіка: похідний прапорець `_topology_db_scope`

Профіль не розноситься по ролях як набір умов. Він дає **один** похідний
прапорець у `roles/topology`:

```
_topology_db_scope: dc        # singlehost, multihost, failover, warm_standby
_topology_db_scope: global    # stretch
```

Зараз три місця жорстко фільтрують по локальному DC. Вони і є споживачами:

| Місце | Зараз | При `global` |
|---|---|---|
| `roles/consul/defaults/main.yml:3` | `consul_datacenter: "{{ datacenter }}"`; `consul_server_hosts` фільтрує по ньому; `bootstrap_expect` = довжина фільтрованого списку | одне спільне ім'я DC на всі сайти; `consul_server_hosts` = всі `consul_server`; `bootstrap_expect` = глобальна к-ть |
| `roles/patroni/defaults/main.yml` | `patroni_cluster_hosts` фільтрує по `datacenter` | усі ноди групи `patroni` незалежно від DC |
| `roles/haproxy/defaults/main.yml:12` | `haproxy_backends` фільтрує patroni по `datacenter` | глобальний список (див. нижче) |

**Що з HAProxy насправді.** RW-листенер уже резолвить через Consul DNS за тегом
(`{{ haproxy_pg_primary_tag }}.{{ webitel_patroni_scope }}.service.consul`), тож у
єдиному Consul-DC він знаходить глобального лідера сам — тут нічого правити.
`haproxy_backends` впливає на два інші аспекти:

1. **Gating** — листенери взагалі не рендеряться при порожньому списку.
2. **К-ть слотів `server-template`** RO-листенера. Ось де stretch ламається: при
   DC-фільтрації слотів буде стільки, скільки локальних patroni-нод, тоді як
   `replica.<scope>.service.consul` віддасть репліки з усіх DC. Три слоти на
   дев'ять реплік — частина реплік недосяжна, а зайняті слоти можуть виявитися
   віддаленими.

При `global` к-ть слотів має рахуватися глобально.

## Інпути, специфічні для `stretch`

Це не приховані дефолти, а явні параметри: вони кодують обіцянки RPO і латентності.

- **`consul_raft_multiplier`** — Consul raft налаштований на LAN. Для міжсайтового
  лінка таймаути heartbeat/leader-lease треба розширювати.
- **`ttl` / `loop_wait` / `retry_timeout` Patroni** — те саме: дефолти розраховані
  на локальну мережу. Дефолт профілю розрахувати під ~10–30 ms RTT.
- **`patroni_synchronous_mode`** — без нього автоматичний failover у інший DC
  втрачає останні транзакції; з ним кожен коміт платить WAN round-trip. Вибір
  користувача, не наш дефолт.

## Інваріанти поза профілем

Ці асерти діють завжди, незалежно від профілю:

- кворум DCS непарний і ≥3 у `failover`, `warm_standby`, `stretch`;
- patroni ≥2 ноди на кластер (3 рекомендовано);
- patroni-кластер не перетинає DC, окрім `stretch`;
- RabbitMQ-кластер і `nomad_server` не перетинають DC **у жодному профілі**,
  включно зі `stretch`;
- хост не може бути одночасно в групах `postgres` і `patroni`;
- кожен DC з хостами має ≥1 `consul_server` (безумовно, в усіх профілях);
- `warm_standby` вимагає `primary_datacenter`, і він має бути серед наявних DC;
- `stretch` вимагає ≥3 DC, а сервери DCS — рівно в трьох fault domains,
  незалежно від загальної к-ті DC;
- `dns_upstream_servers` задано на кожному хості.

## Що видаляється

Чотири булеві замінює профіль і його таблиця очікуваних scope:

- `consul_allow_multidc`
- `patroni_allow_multidc`
- `nomad_allow_multidc`
- `rabbitmq_allow_stretch`

## Поза матрицею

- **etcd.** Consul покриває всі п'ять профілів, включно з N-DC. Власний raft-DCS
  Patroni (pysyncobj) deprecated у 3.x і видалений у 4.x, тож на дистро-пакеті
  Debian 13 його не буде. Якщо etcd знадобиться — це окреме рішення з іншим
  обґрунтуванням.
- **Witness / arbiter-вузол.** Мав би сенс лише для автоматичного failover на двох
  DC. Оскільки на двох DC перемикає утиліта, а на трьох кворум є природно, потреби
  немає в жодному профілі.
- **Stretch на 2 DC.** Заборонений: два fault domains не дають кворуму.
- **Два DC без реплікації.** Не профіль. Два primary без зв'язку розходяться в
  даних за побудовою. Або DC реплікуються (`warm_standby`), або це дві окремі
  інсталяції `failover` з двома інвентарями.

## Відомі розбіжності з поточним кодом

Формалізація виявляє чотири місця, де код не відповідає матриці. Це не задачі
цієї спеки, але вони мають бути в плані:

1. **Документація відстала від коду щодо `standby_cluster`.** Реплікація між DC
   **реалізована**: блок `standby_cluster` є в `roles/patroni/templates/patroni.yml.j2`
   під `patroni_is_standby`, `patroni_standby_cluster_host` збирає кома-список IP
   primary-DC, `roles/topology` виводить `patroni_is_standby_dc` і
   `_topology_patroni_primary_hosts`, а `pg_hba` вже видає replication-рядки на
   `groups['patroni']` усіх DC. Застарілі твердження, які треба виправити:
   `README.md:100` («cross-DC replication ... is phase 3, not yet implemented»),
   план `2026-06-17-patroni-warm-standby-2dc.md` (21 крок без жодної позначки
   виконання) і memory-нотатка `project-phase3-standby-design`.
   Реально нереалізованим з фази 3 лишається тільки guard проти відкоту promote
   (див. нижче) і live promotion, яку свідомо не робимо.
2. **Prepared queries створюються лише в одному DC.**
   `roles/consul/tasks/prepared_queries.yml` виконується з `run_once: true` і
   `delegate_to: groups['consul_server'][0]`. При ізольованих per-DC Consul
   (`warm_standby`) другий DC не отримає `webitel-api` і `webitel-messages-bot`,
   тож nginx там резолвитиме `webitel-api.query.consul` у NXDOMAIN
   (`roles/nginx/tasks/configure.yml:25`). Має виконуватися раз **на кожен**
   Consul-кластер.
3. **К-ть слотів RO-листенера HAProxy** при `global` scope (описано вище).
4. **Локальність читань у `stretch` не вирішена.** `replica.<scope>.service.consul`
   віддає репліки з усіх DC без пріоритету близькості. Prepared query з `Near`
   або фільтр по node-meta — окреме рішення; поточні prepared queries роблять лише
   аліасинг імен, без `Near`.

## Свідомо не робимо

- **Live promotion засобами Ansible.** `bootstrap.dcs` ігнорується після першого
  старту, тож зняття `standby_cluster` потребує окремого ідемпотентного кроку
  через REST/`patronictl edit-config`. Це робота утиліти, не плейбука.
- **Replication slot для standby-кластера.** Warm standby приймає rebuild при
  сильному відставанні.
- **Виведення профілю з інвентаря.** Профіль оголошується. Виведення повернуло б
  нас до поточної ситуації, де підтримувана множина не має імені.
