# Role: topology

Turns the inventory's shape into variables, so nothing has to be hand-duplicated in
`group_vars`. It installs no packages and touches no host.

Two entry points:

- `tasks/main.yml` (default) — derives the facts: `single_node`, `ha_mode`,
  `nomad_managed`, `pg_major`, dependency addresses (`webitel_pg_host`,
  `webitel_amqp_host`, …), connection strings, `webitel_public_url`, `proxy_env`.
  Driven by `playbooks/topology.yml`, which every domain playbook imports first so
  standalone runs (`database.yml`, `web.yml`, …) resolve the same values.
- `tasks/validate.yml` — asserts the inventory matches its declared
  `topology_profile`. Reads inventory data only (groups, static hostvars), never
  facts, so it runs on `localhost` without SSH. Driven by
  `playbooks/validate_topology.yml`, which `preflight.yml` imports.

```yaml
- ansible.builtin.include_role:
    name: topology
    tasks_from: validate
```

## `vars/main.yml` — the profile contract

`topology_profiles` defines what each deployment profile is allowed to look like
(datacenter and host bounds, `db` shape, `dcs_scope`). It lives in `vars/`, not
`defaults/`: overriding it in `group_vars` would defeat the gate. `tasks/validate.yml`
checks against it; `tasks/main.yml` reads `dcs_scope` from it to derive
`_topology_db_scope`.

## `defaults/main.yml` — the tunables

Cluster-wide service credentials, PKI paths, and the 10030–10048 listener port block.
These are the inputs; everything in `tasks/main.yml` is derived from them plus the
inventory. Override them in `group_vars/all/main.yml`, never the derived facts —
`set_fact` (precedence 18) would win over a `group_vars` value and silently discard it.
Per-dependency escape hatches are the `external_*` variables (`external_pg_host`,
`external_amqp_url`, `external_consul_host`, …), which each expression checks first.
