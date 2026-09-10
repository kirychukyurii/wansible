# webitel_service

Generic, data-driven role for all Webitel microservices. Installs the deb
package, edits the package-shipped env file in place (`lineinfile`, key by
key), and enables the systemd units. Replaces the separate `webitel_engine`,
`webitel_logger`, `webitel_storage`, `webitel_cases`, `webitel_call_center`,
`webitel_flow_manager`, `webitel_messages`, `webitel_media_exporter`,
`webitel_core` roles.

## Usage

```yaml
- name: Webitel engine
  hosts: webitel_engine
  become: true
  roles:
    - { role: webitel_service, webitel_service_name: engine, tags: [webitel_engine] }
```

## Input

| Variable | Description |
|---|---|
| `webitel_service_name` | Required. Service name; selects which `vars/services/<name>.yml` gets loaded |
| `webitel_service_env_extra` | dict of env keys overriding every env block's env (per-host; applied to all files in multi-unit services) |

## Service catalog (`vars/services/<name>.yml`)

A single `webitel_service_spec` dict:

| Key | Default | Description |
|---|---|---|
| `package` | — (required) | deb package name |
| `units` | `[package]` | list of systemd units |
| `env_files` | `[]` | list of env blocks `{path, env}`, one per unit for multi-unit packages (core api/app/uac/portal, messages srv/bot). Each file ships with the package; the role overrides keys in place. Empty/missing skips the env configuration step |

Each `env_files` entry:

| Key | Description |
|---|---|
| `path` | path to the package's env file; check with `dpkg -L <package> \| grep /etc/default/` |
| `env` | dict of env keys (values are Jinja, referencing shared group_vars) |

## Tunables (ports, DSN, log level)

Ports, DSN parameters, and log level are configured via typed, namespaced vars
in `group_vars`/`host_vars`. Defaults live in `roles/topology/defaults` and are
frozen into facts (single source of truth; nginx reads the same variables).
Without overrides, behavior matches upstream.

### Listener ports: single firewall block 10030-10048

| Service | listener | knob | port | nginx |
|---|---|---|---|---|
| engine | gRPC | `webitel_engine_grpc_port` | 10030 | |
| engine | WebSocket | `webitel_engine_websocket_port` | 10031 | yes |
| call_center | gRPC | `webitel_call_center_grpc_port` | 10032 | |
| flow_manager | gRPC | `webitel_flow_manager_grpc_port` | 10033 | |
| flow_manager | web | `webitel_flow_manager_web_port` | 10034 | |
| flow_manager | ESL | `webitel_flow_manager_esl_port` | 10035 | |
| storage | gRPC | `webitel_storage_grpc_port` | 10036 | |
| storage | public HTTP | `webitel_storage_public_port` | 10037 | yes |
| storage | internal HTTP | `webitel_storage_internal_port` | 10038 | |
| messages | micro service | `webitel_messages_service_port` | 10039 | |
| messages | bot HTTP | `webitel_messages_bot_port` | 10040 | yes |
| logger | gRPC | `webitel_logger_grpc_port` | 10041 | |
| cases | gRPC | `webitel_cases_grpc_port` | 10042 | |
| media_exporter | gRPC | `webitel_media_exporter_grpc_port` | 10043 | |
| core api | micro-gRPC | `webitel_core_api_grpc_port` | 10044 | |
| core app | micro-gRPC | `webitel_core_app_grpc_port` | 10045 | |
| core uac | micro-gRPC | `webitel_core_uac_grpc_port` | 10046 | |
| core portal | micro-gRPC | `webitel_core_portal_grpc_port` | 10047 | |
| messages bot | micro-gRPC | `webitel_messages_bot_service_port` | 10048 | |

> core (api/app/uac/portal) and messages-bot micro-gRPC use `MICRO_SERVICE_ADDRESS`
> on the **host IP + fixed port** (consul-advertised). `MICRO_API_ADDRESS`
> (HTTP gateway api, :8080) is also `{{ webitel_core_bind_host }}:8080` (single ->
> `127.0.0.1:8080`, multihost -> `hostIP:8080`); the key is commented out in
> `.env.api.example`, so we set it explicitly.

`nginx: yes` marks the listener nginx proxies to; the port comes from the same
knob (the `nginx` role rewrites both host and port). Note: the nginx rewrite
only takes effect on the first run against a freshly downloaded shipped config
(`/etc/nginx/sites-enabled/default`). Changing the port after the first apply
requires restoring the shipped config (delete the file so `get_url` re-downloads
it) or a manual edit.

### DSN / AMQP tuning (two-level: cluster, then service)

| knob (cluster) | default | per-service override |
|---|---|---|
| `webitel_pg_sslmode` | `disable` | `webitel_<svc>_pg_sslmode` |
| `webitel_pg_connect_timeout` | `10` | `webitel_<svc>_pg_connect_timeout` |
| `webitel_amqp_heartbeat` | `10` | `webitel_<svc>_amqp_heartbeat` |

`search_path` is hardcoded (schema contract, not tunable).

### Log level (two-level)

`webitel_log_level` applies cluster-wide; `webitel_<svc>_log_level` overrides it
per service. With neither set, each service stays on its upstream default
(`debug` for engine/call_center/flow_manager/storage, `info` for messages,
`trace` for core). The `logger`/`cases`/`media_exporter` services have no log
level env key, so they aren't controlled here.

### Service-specific

| knob | default | service |
|---|---|---|
| `webitel_storage_media_directory` | `/opt/storage/data` | storage |
| `webitel_call_center_omnichannel` | `0` | call_center |

## Tags

- `install` / `configure`: phases (all services)
- `webitel_<name>`: applied at the include level in the playbook (whole service)
- Scope to one service: `--limit webitel_<name> --tags <phase>`

## Notes

Check env file paths with `dpkg -L <package> | grep /etc/default/`.
`lineinfile` without `create: yes` fails loudly if the file is missing (intentional).
