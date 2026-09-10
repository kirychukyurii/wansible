# nginx TLS modes (Блок 3.1)

**Дата:** 2026-06-20
**Статус:** дизайн узгоджено, план не написано

## Проблема

nginx у Webitel — публічний reverse-proxy, віддає назовні домен (`nginx_site_name`,
напр. `contact1/contact2.kcsd.kz`). Зараз TLS обробляється лише в одному режимі:

- `nginx_letsencrypt: true` → роль `certbot` бере справжній Let's Encrypt серт,
  ставить `server_name`, додає `--redirect`. Працює для публічних доменів.
- `nginx_letsencrypt: false` (так **скрізь зараз**, включно з production `kcsd.kz`)
  → роль `nginx` **не торкається** `ssl_certificate`. HTTPS тримається на тому, що
  зашите в завантаженому `default`-конфізі Webitel: або шлях у `/etc/letsencrypt/...`
  (якого без certbot не існує → nginx не підніметься), або snakeoil зі `ssl-cert`
  пакета (CN=хост, browser warning). Тобто дірка.

PKI-серти (роль `pki`) для цього **не підходять за визначенням**: це внутрішній mTLS,
`CN=hostname`, ECDSA, CA не публічно-довірений. nginx віддає назовні домен — інший
CN/SAN і потрібен довірений ланцюг. Перевикористання виключене.

Реальний кейс `kcsd.kz` — держ-інфраструктура Казахстану, публічний Let's Encrypt
туди швидше за все не дотягнеться → серт приходить з корпоративного CA (BYO).

## Рішення: три взаємовиключні режими TLS

Нова змінна `nginx_tls_mode` ∈ `letsencrypt | provided | self_signed`.

### Модель змінної (back-compat)

```yaml
# roles/nginx/defaults/main.yml
nginx_tls_mode: "{{ 'letsencrypt' if nginx_letsencrypt | default(false) | bool else 'self_signed' }}"
```

- Усі інвентарі, що зараз на `nginx_letsencrypt: false`, **автоматично** стають
  `self_signed` → HTTPS працює з коробки, поточна дірка закрита.
- `nginx_letsencrypt: true` живе без змін (резолвиться в `letsencrypt`).
- Оператор може задати `nginx_tls_mode` напряму (напр. `kcsd.kz` → `provided`).
- `nginx_letsencrypt` лишається як back-compat toggle; формально не видаляємо.

### Канонічний шлях сертів

```
/etc/nginx/ssl/{{ nginx_site_name }}.crt   # 0644
/etc/nginx/ssl/{{ nginx_site_name }}.key   # 0640
```
Директорія `/etc/nginx/ssl` створюється роллю (`0755`).

### Патч конфіга

Для `provided` та `self_signed` роль патчить у завантаженому `default`-сайті
(той самий `ansible.builtin.replace`-патерн, що вже використовується для upstream'ів):

- `ssl_certificate` → канонічний `.crt`
- `ssl_certificate_key` → канонічний `.key`
- `server_name` → `{{ nginx_site_name }}`

Режим `letsencrypt` **не чіпаємо** — certbot сам володіє своїми шляхами,
`server_name` і `--redirect`.

### Гілка `self_signed`

Дзеркало pki-ролі (`community.crypto` вже в `requirements.yml`, pki вже її юзає):

- `community.crypto.openssl_privatekey` → канонічний `.key`
- `community.crypto.x509_certificate` `provider=selfsigned`:
  - `CN = {{ nginx_site_name }}`
  - `subject_alt_name = ["DNS:{{ nginx_site_name }}"]`
  - валідність ~825 днів
- Ідемпотентно (`force: false`).

Browser warning — прийнятно для не-публічних/dev/internal деплоїв.

### Гілка `provided` (BYO)

- Оператор задає `nginx_tls_cert` / `nginx_tls_key` як **шляхи на контролері**
  (обовʼязкові; перевіряється в preflight).
- Роль копіює ключ у канонічний шлях (`ansible.builtin.copy`).
- Серт:
  - якщо `nginx_tls_chain` **не** заданий — `nginx_tls_cert` копіюється як є
    (має вже містити повний ланцюг);
  - якщо `nginx_tls_chain` непорожній (СПИСОК intermediate CA на контролері, у
    порядку ланцюга) — роль збирає fullchain одним файлом: читає leaf і кожен
    intermediate на контролері через `lookup('file')` і кладе як `content` у
    канонічний шлях. Без staging-теки → зміна/скорочення ланцюга не лишає застарілих
    фрагментів і не потребує ручного чищення; `copy` порівнює фінальний вміст →
    ідемпотентно. Зручно для DigiCert-подібних бандлів і ротації без ручного `cat`.

## Структура

- Нова `roles/nginx/tasks/tls.yml` — інклудиться з `roles/nginx/tasks/main.yml`
  після `configure`; диспатчить за `nginx_tls_mode` лише для `provided`/`self_signed`.
- `letsencrypt` лишається в `playbooks/web.yml`, але гейт змінюємо:
  `nginx_letsencrypt | bool` → `nginx_tls_mode == 'letsencrypt'`.
- Розподіл відповідальності: роль `certbot` = тільки LE; роль `nginx` = власні серти.

## preflight (playbooks/preflight.yml)

- `nginx_tls_mode in ['letsencrypt', 'provided', 'self_signed']`.
- `provided` → `nginx_tls_cert` і `nginx_tls_key` задані; source-файли існують на контролері.
- `self_signed` → `nginx_site_name` заданий (потрібен для CN).
- `letsencrypt` → `nginx_site_name` і `nginx_mail_address` задані (існуючий assert,
  переписати гейт із `nginx_letsencrypt` на `nginx_tls_mode == 'letsencrypt'`).

## Поза скоупом

- HSTS / TLS-параметри (ciphers, protocols) — лишаємо як у shipped-конфізі.
- Автоматичне продовження для `provided`/`self_signed` (для LE вже є monthly cron).
- Інтеграція з Consul DNS для upstream'ів — це окремий пункт 3.2.
