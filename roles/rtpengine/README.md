# rtpengine

Installs and configures ngcp-rtpengine from the Sipwise APT repository for Webitel media relay.

## Configuration approach

The RTPEngine config file is downloaded from `rtpengine_config_url`
using `get_url` with `force: false` (first-run-only download), then patched with idempotent
`lineinfile`/`replace` tasks for address substitution. This is a deliberate deviation from
the full-template convention because the upstream config is maintained and
updated independently of this Ansible role (see `defaults/main.yml` for the current default URL).

## Variables

See `defaults/main.yml` for configurable variables.

## Address resolution

- In `global` mode with a private interface: fetches public IP via `community.general.ipify_facts`
  and sets `interface = <private>!<public>` in rtpengine.conf for NAT traversal.
- In `local` mode (or `global` on a host with a public interface): sets only the private IP.
- In multi-node deployments (`single_node: false`): also sets `listen-ng = <private>:60000`.
