# postgres

Standalone PostgreSQL for Webitel: installs the PGDG and TimescaleDB repositories, PostgreSQL packages, and Webitel extensions, then configures parameters and initializes the database.

Supported combinations: Debian 12 / PostgreSQL 15, Debian 13 / PostgreSQL 18 (version determined by `pg_major`, set by the preflight play).

Base packages and database bootstrap are delegated to the `postgres_common` role (repositories, packages, create user/db, restore schema). User/password/schema configuration is done via `postgres_common_*` variables (see `roles/postgres_common/README.md`).

See `defaults/main.yml` for configurable variables.

> Verify the actual paths of `postgres_common_schema_files` and `postgres_helper_sql` after installing the `webitel-postgresql-migrations` package on a test VM, using `dpkg -L webitel-postgresql-migrations`. Update `roles/postgres_common/defaults/main.yml` if they differ.
