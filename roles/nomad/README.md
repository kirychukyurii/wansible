# nomad

Installs and configures HashiCorp Nomad (server + client mode) with optional systemd-driver plugin support.

## Requirements

- Ansible-core >= 2.16
- Debian/Ubuntu target (HashiCorp apt repository)
- `pki` role run before this role when TLS is enabled (`consul_pki_enabled: true`)

## Role variables

See `defaults/main.yml` for configurable variables.

## Tags

Tags: `nomad_install`, `nomad_configure` — see `tasks/main.yml`.

## Notes

- The `nomad_systemd_driver_install` default `none` means the cluster starts without the driver; Nomad jobs requiring the systemd driver need `apt` or `url` (phase 3).
- The `plugin "nomad-driver-systemd"` block in `nomad.hcl.j2` is rendered only for the `client` role.
- TLS is activated when `consul_pki_enabled` is true (set in HA inventory `group_vars`). The `pki` role must run before this role in `site.yml`.
- `consul_pki_enabled`, `single_node`, and `pki_remote_dir` are referenced with `| default(...)` guards so the role is safe to lint and syntax-check without HA inventory variables defined.

## `[VM]` verification

```bash
nomad server members          # expect server nodes alive
nomad node status             # expect client nodes ready
```
