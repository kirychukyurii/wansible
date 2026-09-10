# Дизайн: розповсюдження підписного ключа webitel-storage

**Дата:** 2026-06-23
**Статус:** узгоджено

## Проблема

`webitel-storage` підписує медіа-URL приватним RSA-ключем `/opt/storage/key.pem`.
Якщо ключа нема, сервіс на старті генерує власний:

```sh
KEY=/opt/storage/key.pem
if [ ! -f "$KEY" ]; then
    openssl genrsa -out "$KEY" 2048
    chown webitel:webitel "$KEY"
    chmod 600 "$KEY"
fi
```

Той самий ключ потрібен сервісам-споживачам **engine** і **flow_manager** (вони
читають його з того ж шляху `/opt/storage/key.pem`), а у warm-standby 2-DC — ще й
storage-вузлу другого ДЦ: після failover раніше підписані URL мають лишатися
валідними. Зараз у плейбуку немає жодного механізму, який зводив би ключ до
єдиного значення на всіх вузлах і в обох ДЦ — кожен storage генерує свій,
несумісний з рештою.

## Рішення (огляд)

Контролер — єдине джерело істини для ключа (дзеркалить роль `pki`, де CA-ключ
живе на контролері). Ключ генерується раз, зберігається в інвентарі
(git-ignored) і байт-ідентично розкладається на всі вузли-споживачі в обох ДЦ.
Один ключ на весь деплой ⇒ після failover усі підписані URL валідні в ДЦ-B без
додаткової синхронізації.

Варіант «дочекатись, поки сервіс згенерує ключ → fetch з активного вузла →
роздати» відкинуто: складніший, має проблему черговості (chicken-and-egg) і
зайвий під nomad. Оскільки сервіс **поважає вже наявний** `key.pem` (генерує
лише за відсутності), Ansible може просто підкласти канонічний ключ — це
повністю ідемпотентно.

## Компоненти

### 1. Роль `webitel_storage_key`

**`roles/webitel_storage_key/defaults/main.yml`:**

```yaml
webitel_storage_key_local_path: "{{ inventory_dir }}/storage/key.pem"  # контролер, git-ignored
webitel_storage_key_remote_path: /opt/storage/key.pem
webitel_storage_key_owner: webitel
webitel_storage_key_group: webitel
webitel_storage_key_mode: "0600"
webitel_storage_key_type: RSA
webitel_storage_key_size: 2048
```

**`roles/webitel_storage_key/tasks/main.yml`** — дві фази:

*Фаза генерації (контролер, `run_once: true`, `become: false`, `delegate_to: localhost`):*
- `file:` створити `{{ inventory_dir }}/storage/` `0700`.
- `community.crypto.openssl_privatekey:` → `webitel_storage_key_local_path`,
  `type: RSA`, `size: 2048`, **`format: pkcs1`**, `mode: "0600"`.
  `format: pkcs1` відтворює рівно те, що дав би `openssl genrsa`
  (`-----BEGIN RSA PRIVATE KEY-----`), а не дефолтний для модуля PKCS#8.
  Ідемпотентно: модуль не перегенерує наявний валідний ключ.

*Фаза розкладки (на кожному хості плею):*
- `set_fact` `_webitel_storage_key_units` — юніти, що є на цьому хості (за
  членством у групах), для адресного рестарту:

  ```yaml
  _webitel_storage_key_units: >-
    {{ (['webitel-storage'] if inventory_hostname in groups['webitel_storage'] | default([]) else [])
     + (['webitel-engine'] if inventory_hostname in groups['webitel_engine'] | default([]) else [])
     + (['webitel-flow-manager'] if inventory_hostname in groups['webitel_flow_manager'] | default([]) else []) }}
  ```

- `file:` створити `/opt/storage` (`owner/group=webitel`, `0755`) — потрібно на
  engine/flow_manager-вузлах, де пакета storage нема.
- `copy:` `src=webitel_storage_key_local_path` →
  `webitel_storage_key_remote_path`, `owner/group=webitel`, `mode=0600`.
  Змінюється лише коли вміст відрізняється → `notify` хендлера рестарту.

**`roles/webitel_storage_key/handlers/main.yml`:**

```yaml
- name: Restart webitel services using storage key
  ansible.builtin.systemd_service:
    name: "{{ item }}"
    state: restarted
  loop: "{{ _webitel_storage_key_units }}"
  when: not (nomad_managed | default(false))
```

### 2. Інтеграція в `playbooks/webitel.yml`

Плей storage-key додається **в кінець** файлу — після всіх сервісних плеїв:

```yaml
- name: Webitel storage signing key
  hosts: webitel_storage:webitel_engine:webitel_flow_manager
  become: true
  any_errors_fatal: "{{ fail_fast | default(true) }}"
  environment: "{{ proxy_env | default({}) }}"
  roles:
    - { role: webitel_storage_key, tags: [webitel_storage_key] }
```

Розташування в кінці гарантує, що пакети webitel-* уже встановлено (юзер
`webitel` існує), тож `copy`/`file` з `owner: webitel` коректні.

### 3. `.gitignore`

Додати `inventories/*/storage/` (поряд з наявним `inventories/*/pki/`), щоб
приватний ключ не потрапив у git.

## Потік даних

```
контролер: openssl_privatekey(RSA 2048, pkcs1)
           → inventories/<env>/storage/key.pem        (раз, ідемпотентно)
   └─ copy ─→ dc_a_storage:/opt/storage/key.pem        (webitel:webitel 0600)  → restart webitel-storage
   └─ copy ─→ dc_a_app(engine):/opt/storage/key.pem                            → restart webitel-engine
   └─ copy ─→ dc_a_switch(flow_manager):/opt/storage/key.pem                   → restart webitel-flow-manager
   └─ copy ─→ dc_b_storage / dc_b_app / dc_b_switch     (той самий байт-у-байт ключ)
```

## Поведінка за режимами

- **systemd (single/multihost):** сервіси стартували у своїх плеях (storage — зі
  своїм самозгенерованим ключем; engine/flow — без ключа). Плей storage-key
  наприкінці підкладає канонічний ключ → handler рестартить лише ті юніти, що є
  на хості, щоб підхопили канонічний ключ.
- **nomad (warm-standby/failover):** Ansible не стартує юніти; ключ просто лежить
  на місці. Handler пропущено (`nomad_managed`), бо лайфциклом задач керує nomad —
  він підніме сервіс уже з ключем.

## Крайові випадки

- **Формат:** `format: pkcs1` ⇒ байт-сумісно з `openssl genrsa`.
- **Сервіс уже згенерував власний ключ:** `copy` перетре його канонічним.
  Навмисно — мета єдиний ключ на деплой. (Для вже-проду зі старими підписаними
  URL це треба враховувати окремо; для нового деплою неактуально.)
- **`/opt/storage` на engine/flow_manager:** створюємо явно; юзер `webitel`
  гарантовано є, бо плей іде після встановлення пакетів.
- **Ідемпотентність:** повторний прогон — нуль змін, без рестартів.

## Тестування

- Перший прогон: ключ створено локально; розкладено на всі storage/engine/
  flow_manager-вузли; правильні власник/права; `openssl rsa -in key.pem -check`;
  перший рядок `-----BEGIN RSA PRIVATE KEY-----`.
- Байт-ідентичність: `sha256sum /opt/storage/key.pem` однаковий на dc_a_storage і
  dc_b_storage.
- Другий прогон: `changed=0`, жодного рестарту.
