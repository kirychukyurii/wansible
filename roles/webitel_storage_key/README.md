# Role: webitel_storage_key

Generates the `webitel-storage` URL-signing key once on the Ansible controller and distributes it byte-identically to every consuming host (storage, engine, flow_manager) across both datacenters.

## Overview

`webitel-storage` signs media URLs with an RSA private key at `/opt/storage/key.pem`. If the file is missing, the service generates its own on first start (`openssl genrsa 2048`). The consumers `webitel-engine` and `webitel-flow-manager` read the **same** key from the same path, and in a warm-standby 2-DC layout the standby-DC storage node needs it too — so URLs signed before a failover stay valid afterwards.

This role makes the controller the single source of truth: one key per deployment, generated once and copied everywhere. Because the service respects a pre-existing key, the role just pre-seeds the canonical one — fully idempotent.

- The key is created once on the controller under `webitel_storage_key_local_path` (defaults to `{{ inventory_dir }}/storage/key.pem`), in **PKCS#1** format to match `openssl genrsa` exactly.
- It is copied to `webitel_storage_key_remote_path` (`/opt/storage/key.pem`) on each host, owned `webitel:webitel`, mode `0600`.
- When the key changes, affected units on the host are restarted — **skipped under nomad** (`nomad_managed`), where nomad owns service lifecycle.

**Important:** The signing key is stored only on the controller in `webitel_storage_key_local_path`. This directory is excluded from version control via `.gitignore` (`inventories/*/storage/`). Losing it (without a copy on a managed host) means a new key — and all previously signed URLs break. Back it up securely.

## Requirements

Collection `community.crypto` must be installed on the controller (listed in `requirements.yml`).

## Variables

See `defaults/main.yml` for configurable variables.

## Tags

Tag: `webitel_storage_key` (run_once, controller-side generation + distribution).

## Usage

Applied as the final play in `playbooks/webitel.yml`, after the service plays — so packages (and the `webitel` user) exist and services have started, then the canonical key is laid down and consumers restarted.

```yaml
- name: Webitel storage signing key
  hosts: webitel_storage:webitel_engine:webitel_flow_manager
  become: true
  roles:
    - { role: webitel_storage_key, tags: [webitel_storage_key] }
```
