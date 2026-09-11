# nginx

Installs NGINX as the Webitel reverse proxy. Downloads the upstream Webitel NGINX configuration on first run (`force: false`), then patches upstream addresses to match the actual inventory topology. Optionally invokes the `certbot` role when `nginx_tls_mode` is `letsencrypt`.

Note: the NGINX config files are owned by the Webitel engineering team and fetched from wherever `nginx_config_url`/`nginx_site_url` point (see `defaults/main.yml` for the current default). The role does not manage the full template; instead it applies idempotent `replace` tasks for upstream addresses.

See `defaults/main.yml` for configurable variables.

The `nginx_site_name` and `nginx_mail_address` variables are consumed by the `certbot` role (included conditionally from `playbooks/web.yml`).

## Consul discovery (multi-host)

In multi-host, nginx resolves upstreams via Consul DNS at runtime (failover without a
reload): backend names are defined as nginx variables (`$storage_backend`, etc.) via an
http-level `map`, inserted with `blockinfile` at the top of `sites-enabled/default`
alongside `resolver 127.0.0.1:8600`. `proxy_pass` uses these variables, so nginx
re-resolves them every `valid=3s`.

| Upstream | Consul name |
|---|---|
| storage | `storage.service.consul` |
| api/core | `webitel-api.query.consul` (prepared query → `go.webitel.api`) |
| messages bot | `webitel-messages-bot.query.consul` (prepared query → `webitel.chat.bot`) |
| engine WS | `engine.service.consul` |
| opensips | `opensips.service.consul` (registered by the nomad job) |

Prepared queries are created by the `consul` role (`prepared_queries.yml`). Grafana and
portal-grpc stay on direct addresses. single_node stays on `127.0.0.1`.

## TLS modes

`nginx_tls_mode` selects how the public certificate is provisioned (mutually exclusive):

| Mode | Behaviour |
|------|-----------|
| `letsencrypt` | Real Let's Encrypt cert via the `certbot` role (`playbooks/web.yml`). Public domains only. |
| `provided` | Operator supplies `nginx_tls_cert` / `nginx_tls_key` (controller-side paths); the role copies them to `/etc/nginx/ssl/<site>.{crt,key}` and enables TLS (see below). For corporate-CA / wildcard certs. Set `nginx_tls_chain` (list of intermediates) to let the role assemble the full chain (leaf + intermediate(s)) on the target. |
| `self_signed` | The role generates a self-signed cert for `nginx_site_name` and enables TLS (see below). Default fallback; browsers show a warning. |

For `provided` / `self_signed` the upstream `default` site ships its TLS directives **commented out** (the active `server{}` listens on `:80` only). The role therefore does not rely on `replace` of cert paths — it actively injects, into managed `blockinfile` regions:

- `listen 443 ssl http2` + `ssl_certificate` / `ssl_certificate_key` (pointing at the managed cert) into the existing content `server{}`, and
- a separate `server{}` on `:80` that `return 301`s to `https://$host$request_uri`.

The managed regions are re-rendered on change, so updating `nginx_tls_cert_path` or `nginx_site_name` reconfigures TLS idempotently. `letsencrypt` mode is untouched — `certbot --nginx --redirect` enables TLS itself.

The default is `self_signed`. Set `nginx_tls_mode` explicitly to pick another mode.

See `defaults/main.yml` for the TLS variables (`nginx_tls_*`).
