# grafana

Installs Grafana OSS, provisions the PostgreSQL data sources, and optionally imports a set of pre-built Webitel analytics dashboards.

Two read-only data sources query the webitel DB through the local HAProxy: **PostgreSQL Primary** (RW endpoint, default) and **PostgreSQL Replica** (RO endpoint, rendered only when HAProxy is present). Both authenticate as a dedicated SELECT-only role (`grafana_datasource_user`). That role and the Grafana backend DB/user are provisioned on the Patroni leader (`roles/patroni` → `bootstrap_db`), since `pg_hba` denies the superuser from the Grafana host; runtime access for the datasource and backend users is allowed by per-user `pg_hba` entries. The backend DB connection (`grafana.ini`) uses the RW endpoint as `grafana_db_user`.

Note: `grafana.ini` is owned by the Grafana package. The role uses a targeted `lineinfile` task for `root_url` rather than a full template, to avoid overwriting package-managed config on upgrades. This is a documented exception to the "full template" convention.

See `defaults/main.yml` for configurable variables.

## Admin credentials

`grafana_admin_user` / `grafana_admin_password` are written to the `[security]` section
of `grafana.ini`. **Caveat:** Grafana applies `admin_password` only when it first creates
the admin user (fresh install). Changing the variable on an already-provisioned instance
does **not** update the existing admin — rotate it on the host with:

```bash
grafana-cli admin reset-admin-password "<new-password>"
```

