# HTTP/HTTPS проксі для install-фази

- **Дата:** 2026-06-16
- **Статус:** Draft (на рев'ю)
- **Репо:** wansible
- **Джерела:** роль `topology` (`roles/topology/tasks/main.yml`) як патерн «group_vars = інпути, set_fact = похідні»; install-таски ролей (`base/repo.yml`, `consul/install.yml` тощо); spec [2026-06-10-webitel-26.4-redesign](2026-06-10-webitel-26.4-redesign-design.md)

## 1. Контекст і мотивація

Частина інсталяцій Webitel живе в мережах, де вихід в інтернет можливий **лише через корпоративний HTTP-проксі**; інша частина має прямий доступ. Зараз у репо немає жодної згадки proxy і жодного `environment:` — провіжинінг просто йде напряму.

Увесь вихідний трафік під час прогону зосереджений в **install-фазі**:
- модуль `ansible.builtin.apt` + `deb822_repository` (репозиторії HashiCorp, HAProxy, RabbitMQ, Webitel);
- `ansible.builtin.get_url` (GPG-ключі: HashiCorp, тощо);
- `apt-transport-s3` (S3-репозиторій Webitel `s3://{{ webitel_repo_s3_bucket }}`);
- `update_cache: true` (apt update).

Усі ці інструменти читають проксі з оточення процесу: `apt-get` — `http_proxy`/`https_proxy`, `get_url` — теж, `apt-transport-s3` (python/boto) — `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`. Отже один механізм (`environment:`) покриває весь егрес install-фази.

**Рантайм сервісів Webitel у скоупі НЕ розглядається** — вони спілкуються лише всередині кластера. Якщо колись окремому сервісу знадобиться вихід назовні через проксі, це робитимуть через env-файли systemd-юнітів окремою ітерацією (поза цією спекою).

## 2. Ухвалені рішення (з обговорення)

1. **Тільки install-фаза.** Рантайм сервісів — на потім, окремою спекою.
2. **Один механізм — `environment:` на рівні плеїв.** Покриває apt, get_url, s3 разом. Не системний apt-конфіг (розмазав би проксі між base-роллю і плеями), не per-task у ролях (розкидало б по 10+ файлах і зламало single-source).
3. **Інпути в `group_vars/all`, похідний dict у `topology`** — рівно патерн наявних DSN/URL: group_vars заповнюють руками (лише інпути), `set_fact` рахує похідне раз на ранньому `hosts: all` плеї.
4. **`no_proxy` з розумними дефолтами**, які рахує `topology`: `localhost,127.0.0.1,::1,.consul` + IP усіх хостів кластера + ручні додатки юзера. **S3-репо лишається через проксі** (зазвичай зовнішній AWS/MinIO).
5. **Немає проксі → повний no-op.** Якщо ні `http_proxy`, ні `https_proxy` не задані — `proxy_env` = `{}`, `environment` нічого не змінює. Проекти без проксі не зачеплені.

## 3. Інпути (group_vars/all/main.yml)

Задаються **лише** в інвентарях, де проксі потрібен:

```yaml
# Вихід в інтернет під час install-фази через корпоративний проксі.
# Не задано — провіжинінг іде напряму (no-op).
http_proxy:  "http://proxy.example.com:3128"
https_proxy: "http://proxy.example.com:3128"   # опційно; дефолтиться на http_proxy
proxy_no_proxy_extra: []                         # опційно: додаткові хости/домени в no_proxy
```

- `https_proxy` необов'язковий — якщо не заданий, дорівнює `http_proxy`.
- `proxy_no_proxy_extra` — список (напр. `["registry.internal", "10.0.0.0/8"]`), додається до автодефолтів.

## 4. Похідний факт `proxy_env` (roles/topology/tasks/main.yml)

Нова секція в кінці `topology` (після наявних кроків). Логіка:

- **Гард:** якщо `http_proxy is not defined and https_proxy is not defined` → `proxy_env: {}` і вихід (no-op).
- **Інакше** будуємо `no_proxy`-рядок:
  - база: `localhost,127.0.0.1,::1,.consul`;
  - + IP усіх хостів кластера: `groups['all'] | map('extract', hostvars) | selectattr('ansible_default_ipv4.address','defined') | map(attribute='ansible_default_ipv4.address')` (факти вже зґейзерені — наявний код уже читає `ansible_default_ipv4`);
  - + `proxy_no_proxy_extra`;
  - усе через кому, унікалізовано.
- Збираємо dict `proxy_env` з ключами в **обох регістрах** (apt читає нижній `http_proxy`; boto/s3 надійніше з верхнім `NO_PROXY`):
  - `http_proxy`, `HTTP_PROXY` ← `http_proxy`;
  - `https_proxy`, `HTTPS_PROXY` ← `https_proxy | default(http_proxy)`;
  - `no_proxy`, `NO_PROXY` ← обчислений рядок.

Псевдо-набросок (фінальний вигляд — на етапі реалізації, узгоджено зі стилем наявних `set_fact`):

```yaml
- name: Resolve install-time proxy environment
  ansible.builtin.set_fact:
    proxy_env: >-
      {{ {} if (http_proxy is not defined and https_proxy is not defined)
         else {
           'http_proxy':  (http_proxy  | default(https_proxy)),
           'HTTP_PROXY':  (http_proxy  | default(https_proxy)),
           'https_proxy': (https_proxy | default(http_proxy)),
           'HTTPS_PROXY': (https_proxy | default(http_proxy)),
           'no_proxy':  _proxy_no_proxy,
           'NO_PROXY':  _proxy_no_proxy,
         } }}
```

(де `_proxy_no_proxy` — попередньо обчислений рядок; точне розбиття на кроки/проміжні факти — за стилем сусідніх секцій topology).

## 5. Застосування на плеях

У кожному компонентному плейбуці, який має install-таски, додати на **кожен play** keyword:

```yaml
environment: "{{ proxy_env | default({}) }}"
```

Зачіпає плеї в:
- `playbooks/infra.yml`
- `playbooks/database.yml`
- `playbooks/messaging.yml`
- `playbooks/voice.yml`
- `playbooks/web.yml`
- `playbooks/webitel.yml`
- `playbooks/preflight.yml` (якщо там є мережеві перевірки/install)

Плей `topology` сам егресу не робить — йому `environment` не потрібен (саме він рахує `proxy_env`). `topology.yml` імпортується на початку кожного компонентного плейбука, тож при будь-якому запуску факт `proxy_env` уже визначений до перших install-тасків.

`| default({})` — дешева страховка на випадок запуску плею без попереднього `topology` (factted always-defined, але keyword лишається валідним).

## 6. Документація

- Закоментовані ключі (`http_proxy`/`https_proxy`/`proxy_no_proxy_extra`) у **одному** example-інвентарі (`inventories/multihost.example/group_vars/all/main.yml`) з коментарем-поясненням.
- Короткий блок «HTTP proxy (install-time)» у `README.md` репо: коли вмикати, що покриває, що `no_proxy` рахується автоматично.

## 7. Поза скоупом

- Рантайм-проксі для самих сервісів Webitel (env-файли systemd) — окрема майбутня ітерація.
- Автентифікований проксі з логіном/паролем — підтримується автоматично (юзер вписує `http://user:pass@host:port` у `http_proxy`), окремих полів не вводимо (YAGNI).
- Per-host/per-group різні проксі — наразі не потрібні; інпут глобальний у `group_vars/all`. Override на рівні group/host працює стандартним precedence Ansible без додаткового коду.

## 8. Тестування / приймання

- **Проект без проксі:** `http_proxy`/`https_proxy` не задані → `proxy_env == {}` → `environment` порожній, провіжинінг іде напряму (поведінка не змінилась). Перевірка: `ansible -m debug -a "var=proxy_env"` після topology → `{}`.
- **Проект із проксі:** задано `http_proxy` → `proxy_env` містить обидва регістри + коректний `no_proxy` з IP кластера й `.consul`. apt/get_url/s3 ходять через проксі, внутрішні запити (між хостами, localhost, Consul DNS) — напряму.
- **Тільки `https_proxy`:** `http_proxy` дефолтиться на нього (і навпаки).
