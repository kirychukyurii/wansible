# opensips

Installs and configures OpenSIPS from the official APT repository for Webitel SIP proxy.

## Configuration approach

The OpenSIPS config file is downloaded from `opensips_config_url`
using `get_url` with `force: false` (first-run-only download), then patched with idempotent
`replace` tasks for address substitution. This is a deliberate deviation from the full-template
convention because the upstream config is maintained and updated independently
of this Ansible role (see `defaults/main.yml` for the current default URL). Only address substitution variables are managed here.

## Variables

See `defaults/main.yml` for configurable variables.

## Address resolution (multi-node)

In multi-node deployments (`single_node: false`), the following substitutions are applied:

- MI listen address → `ansible_facts.default_ipv4.address`
- PostgreSQL DSN host → `webitel_pg_host` (from group_vars)
- RTPEngine address → `hostvars[groups['rtpengine'][0]].ansible_default_ipv4.address`
- RabbitMQ address → `webitel_amqp_host`:`webitel_amqp_port` (from group_vars)

## fail2ban integration

When `opensips_fail2ban: true`, the `fail2ban.yml` task file is included. It installs
rsyslog and fail2ban, redirects OpenSIPS logs to `/var/log/opensips.log` via LOCAL7
syslog facility, and deploys `filter.d/opensips.conf` and `logrotate.d/opensips`.
