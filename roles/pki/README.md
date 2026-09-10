# Role: pki

Generates a self-signed CA and per-node TLS certificates on the Ansible controller using `community.crypto`, then distributes them to each managed host.

## Overview

- CA key and certificate are created once on the controller under `pki_local_dir` (defaults to `{{ inventory_dir }}/pki`).
- Per-node server and peer (client) certificates are generated and signed on the controller.
- All certificates are copied to `pki_remote_dir` on each managed host.

**Important:** The CA private key (`ca-key.pem`) is stored only on the controller in `pki_local_dir`. This directory is excluded from version control via `.gitignore` (`inventories/*/pki/`). Loss of the CA key means all certificates must be reissued — back up `pki_local_dir` securely.

## Requirements

Collection `community.crypto >= 2.10.0, < 4.0.0` must be installed on the controller (listed in `requirements.yml`).

## Variables

See `defaults/main.yml` for configurable variables.

## Files placed on each host

| File | Mode | Purpose |
|---|---|---|
| `ca.pem` | `0644` | CA certificate (public, trust anchor) |
| `<hostname>.pem` | `0644` | Node server+client certificate (SANs: hostname, localhost, node IP, 127.0.0.1) |
| `<hostname>-key.pem` | `0640` | Node server private key |
| `peer-<hostname>.pem` | `0644` | Peer (client-only) certificate |
| `peer-<hostname>-key.pem` | `0640` | Peer private key |

## Tags

Tags: `pki_ca` (run_once, controller only), `pki_node` (per-node cert generation/distribution) — see `tasks/main.yml`.

## Usage

This role is consumed by `consul`, `nomad`, and `patroni` when `consul_pki_enabled: true`. Apply it before those roles in `playbooks/infra.yml`.

```yaml
- name: Generate and distribute PKI
  hosts: all
  become: true
  roles:
    - role: pki
      when: consul_pki_enabled | default(false) | bool
```
