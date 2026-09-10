# Role: patroni

Deploys PostgreSQL under Patroni with Consul DCS. In HA inventories this role replaces the standalone `postgres` role. Patroni manages the PostgreSQL lifecycle; native `postgresql.service` is disabled.

Repos, base packages, and DB bootstrap are delegated to the `postgres_common` role. DB parameters (`*_app_password`, `*_db`, `*_schema_files`) are set via `postgres_common_*` (see `roles/postgres_common/README.md`).

## Requirements

- Consul agent running on `127.0.0.1:8500` (role `consul` must run first).
- `python3-consul` available in apt (or `patroni[consul]` via pip — [VM]: verify on Debian 12/13).
- `community.postgresql` collection installed (`requirements.yml`).

## Variables

See `defaults/main.yml` for configurable variables.

`patroni_cluster_hosts` follows the deployment profile: under `_topology_db_scope: dc` the cluster is the local datacenter's patroni hosts, under `global` (profile `stretch`) it is every patroni host across all datacenters.

`patroni_ttl` and `patroni_retry_timeout` widen automatically under `global` scope (60/20 vs 30/10), because the DCS quorum then spans sites. Keep `ttl` above `loop_wait + 2 * retry_timeout` if you override them.

`patroni_synchronous_mode` is `false` by default. Turning it on is an RPO decision: without it a failover to another datacenter loses transactions that had not shipped yet; with it every commit pays a WAN round trip.

## Vault variables (set in `vault.yml`)

```yaml
vault_patroni_superuser_password: "..."
vault_patroni_replication_password: "..."
vault_patroni_rewind_password: "..."
vault_patroni_restapi_password: "..."
```

## Tags

Tags: `patroni_install`, `patroni_configure` (see `tasks/main.yml`), `patroni_bootstrap` (creates the app user/db and grafana user/db — leader only).

## [VM] Items to verify on a real cluster

- **Consul service name**: After cluster is up, confirm `dig @127.0.0.1 -p 8600 master.{{ patroni_scope }}.service.consul` resolves to the leader IP.
- **python3-consul vs patroni[consul] pip**: `python3-consul` package availability on Debian 12 (bookworm) / Debian 13 (trixie). If missing, install `patroni[consul]` via pip instead.
- **patroni package version**: Confirm `patroni` deb is available in Debian repos (or add Patroni's own repo). On some Debian versions patroni may need to be installed from pip or a 3rd-party apt source.
- **pg_hba completeness**: Verify the `pg_hba` block covers all webitel service hosts (non-patroni cluster hosts get `host all {{ patroni_app_user }}`; grafana hosts additionally get `host {{ grafana_db_name }} {{ grafana_db_user }}` for the backend DB and `host {{ webitel_pg_db }} {{ grafana_datasource_user }}` for the read-only datasource).
- **Schema paths**: Confirm `/usr/share/postgresql/{{ patroni_major }}/webitel/webitel-db-schema.sql` and `webitel-db-data.sql` exist after `webitel-postgresql-{{ patroni_major }}` is installed.
- **patronictl list**: Run `patronictl -c /etc/patroni/config.yml list` — expect 1 Leader + N-1 Replica, Lag 0.

## Notes

- PGDG and TimescaleDB apt repos plus base PostgreSQL packages are set up by the shared `postgres_common` role (included at install time), because in HA mode the standalone `postgres` role does not run.
- Native `postgresql.service` is disabled and the auto-created cluster is dropped — Patroni bootstraps its own cluster in `/var/lib/postgresql/{{ patroni_major }}/main`.
- DB bootstrap (`bootstrap_db.yml`) runs only on the Patroni leader (REST endpoint returns 200). Non-leaders skip it silently. Besides the webitel app DB it also creates, when a `grafana` group exists, the grafana backend user/db and a SELECT-only datasource role (`grafana_datasource_user`, granted per-schema across the webitel DB + default privileges for the app user). Superuser provisioning must run here on the leader via `127.0.0.1`, since `pg_hba` denies the superuser from the grafana host; the roles then replicate to standbys.
- Schema restore runs only when the database was just created (`patroni_create_db is changed`), making the bootstrap idempotent.
