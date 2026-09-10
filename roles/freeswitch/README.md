# freeswitch

Installs and configures FreeSWITCH from the SignalWire APT repository for Webitel voice processing.

## Configuration approach

Configs are downloaded from `freeswitch_config_base_url` using
`get_url` with `force: false` (first-run-only download), then patched with idempotent
`replace` tasks. This is a deliberate deviation from the full-template convention because
the upstream configs are maintained and updated independently of
this Ansible role (see `defaults/main.yml` for the current default URL). Only the address-substitution variables are managed here.

## Variables

See `defaults/main.yml` for configurable variables. This role also consumes
`webitel_opensips_host`, `webitel_amqp_host`, and `webitel_consul_address` (topology-role
facts from `group_vars`) to populate `outbound_sip_proxy`, `amqp_host`, and `consul_url`
in vars.xml.

## Pending

`[VM]` Verify `vars.xml` regexp patterns against actual 26.4 config structure
(patterns were ported from 23.09/25.08 configs; see `# TODO(VM):` comments in configure.yml).
