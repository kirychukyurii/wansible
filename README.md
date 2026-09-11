<div align="center">
  <h2>
    Webitel 26.6
  </h2>

  <a href="https://github.com/kirychukyurii/wansible/actions?query=workflow%3Areviewdog+event%3Apush+branch%3Amain">
    <img alt="GitHub Actions (lint)" src="https://github.com/kirychukyurii/wansible/workflows/reviewdog/badge.svg?branch=main&event=push">
  </a>
</div>

<!-- TOC -->
  * [Requirements](#requirements)
  * [Quickstart](#quickstart)
  * [Deployment profiles](#deployment-profiles)
  * [Inventory model](#inventory-model)
  * [Secrets and vault](#secrets-and-vault)
  * [Verification commands](#verification-commands)
  * [Tags](#tags)
<!-- TOC -->

## Requirements

- **Ansible controller:** ansible-core >= 2.16, collections from `requirements.yml`
- **Target OS:** Debian 12 (bookworm) or Debian 13 (trixie), amd64
  - Hosts running `postgres` or `freeswitch` **must** be amd64 (packages are amd64-only)
- **Access:** SSH key or password, sudo/become rights on target hosts
- **Credentials:** Webitel S3 APT repository keys (access + secret), SignalWire Personal Access Token for FreeSWITCH
- **Internet access:** direct, or through an HTTP proxy — set `http_proxy` / `https_proxy` in
  `group_vars/all`. It applies to the install phase only (apt, GPG key downloads,
  apt-transport-s3), and `no_proxy` is computed for you from localhost, `.consul` and every
  cluster host IP, so nodes keep talking to each other directly

## Quickstart

```bash
# 1. Install required Ansible collections
ansible-galaxy collection install -r requirements.yml

# 2. Create your inventory from the example — see "Deployment profiles" for which one
cp -r inventories/singlehost.example inventories/production

# 3. Edit host definitions and assign services — see "Inventory model"
$EDITOR inventories/production/01-hosts.yml

# 4. Fill in secret credentials — see "Secrets and vault" for the full key list
cp inventories/production/group_vars/all/vault.yml.example \
   inventories/production/group_vars/all/vault.yml
$EDITOR inventories/production/group_vars/all/vault.yml
ansible-vault encrypt inventories/production/group_vars/all/vault.yml

# 5. Run the playbook
ansible-playbook -i inventories/production site.yml --ask-vault-pass
```

## Deployment profiles

Every inventory declares what it is via `topology_profile` in
`group_vars/all/main.yml`. Preflight refuses to run when the inventory does not match
the declared profile, so unsupported shapes fail before the first package is installed.

| | `singlehost` | `multihost` | `failover` | `warm_standby` | `stretch` |
|---|---|---|---|---|---|
| **Example inventory** | `singlehost.example` | `multihost.example` | `failover.example` | `warm-standby-2dc.example` | none yet |
| **Datacenters** | 1 (single host) | 1 | 1 | 2+ | 3+ |
| **PostgreSQL** | standalone | standalone | one Patroni cluster | primary + N standby clusters | one cluster across all DCs |
| **Consul** | 1 server, loopback | 1 server | 1 cluster, 3+, odd | isolated cluster per DC | one raft, three fault domains |
| **RabbitMQ / Nomad** | single | single | cluster | cluster per DC | cluster per DC |
| **Survives** | nothing | loss of a non-DB host | loss of one node | loss of a datacenter | loss of a datacenter |
| **Promotion** | — | — | Patroni, automatic | external controller, manual | Patroni, automatic |
| **RPO** | last backup | last backup | ~0 (≤ 1 MiB WAL) | replication lag; unbounded once the link degrades | ~0 (≤ 1 MiB WAL), or 0 in sync mode |
| **RTO** | hours | hours (DB) | ~30–45 s | minutes to hours | ~60–90 s |

RPO and RTO are database-layer **targets with the shipped defaults**, not guarantees —
they depend on your link, disk and backup schedule, and none have been measured on
production hardware yet. What bounds them:

- `failover` and `stretch` — `patroni_ttl` (30 s / 60 s) plus promotion time for RTO,
  `maximum_lag_on_failover` (1 MiB) for RPO.
- `warm_standby` — how fast the external controller promotes and reroutes. There is no
  replication slot, so extreme lag means rebuilding the standby rather than catching up.
- `singlehost` and `multihost` — your backup schedule and restore speed. The database is
  a single point of failure in both.

Two caveats:

- RTO is the **database** only — application, DNS and SIP routing add their own.
- Only `failover` and `stretch` promote themselves. `warm_standby` promotion is always
  a decision, carried out by Nomad jobs and the external controller, not by this playbook.

`warm_standby` is N datacenters, not two. At three both it and `stretch` fit, so pick by
what you need: per-DC clusters that the controller promotes, or one cluster that promotes
itself.

`stretch` is active/passive: traffic is served by the datacenter holding the database
leader. It widens Consul and Patroni raft timings automatically (`consul_raft_multiplier`,
`patroni_ttl`, `patroni_retry_timeout`); set `patroni_synchronous_mode: true` if a
cross-DC failover must not lose transactions, at the cost of a WAN round trip per commit.

Two datacenters without replication between them is not a profile: that is two separate
`failover` installations, and they belong in two inventories.

All profiles use the same `site.yml` playbook; the inventory's constructed groups
(`consul_server`, `patroni`, `nomad_server`, `rabbitmq`) determine cluster vs. single-node
behavior automatically. The playbook brings the Nomad cluster up and registers it in
Consul, but deploys no Nomad jobs — scheduling is a separate step.

Validate an inventory without touching any host:

```bash
ansible-playbook -i inventories/<name> playbooks/validate_topology.yml
```

Design rationale: `docs/superpowers/specs/2026-09-10-topology-profiles-design.md`.

## Inventory model

The inventory is **host-centric**: each host declares a `services` list, and
`ansible.builtin.constructed` turns each service name into an Ansible group.

```yaml
# inventories/production/01-hosts.yml
all:
  hosts:
    node1:
      ansible_host: 1.2.3.4
      services:
        - consul_server
        - postgres
        - rabbitmq
        - freeswitch
        - nginx
        - webitel_core
        - webitel_engine
        # ... more services
```

The full set of values `services` accepts lives in
[`playbooks/vars/known_services.yml`](playbooks/vars/known_services.yml); preflight rejects
anything not on that list.

Inspect the resulting groups at any time:

```bash
ansible-inventory -i inventories/production --graph
```

## Secrets and vault

Every secret goes into `inventories/production/group_vars/all/vault.yml`, encrypted with
`ansible-vault`. Each example inventory ships a `vault.yml.example` listing the keys it needs.

```yaml
# Needed by every profile:
vault_webitel_repo_s3_access_key: "..."
vault_webitel_repo_s3_secret_key: "..."
vault_freeswitch_signalwire_key: "..."
vault_webitel_cookie_seed: "<random>"               # openssl rand -hex 32
vault_grafana_admin_password: "<random>"            # optional, defaults to webitel
# Clustered profiles only (failover, warm_standby, stretch):
vault_consul_encrypt_key: "<16-byte base64>"        # consul keygen
vault_rabbitmq_erlang_cookie: "<random>"            # openssl rand -hex 32, same on all nodes
vault_patroni_superuser_password: "<random>"        # openssl rand -hex 16
vault_patroni_replication_password: "<random>"      # openssl rand -hex 16
vault_patroni_rewind_password: "<random>"           # openssl rand -hex 16
vault_patroni_restapi_password: "<random>"          # openssl rand -hex 16
```

```bash
ansible-vault encrypt inventories/production/group_vars/all/vault.yml   # once
ansible-vault edit inventories/production/group_vars/all/vault.yml      # later

# Unlock at run time: prompt, or a password file (never commit it)
ansible-playbook -i inventories/production site.yml --ask-vault-pass
ansible-playbook -i inventories/production site.yml --vault-password-file ~/.vault_pass
```

## Verification commands

After a successful run, confirm cluster health on any cluster node:

```bash
# Consul — all servers should be alive
consul members

# Resolve the Patroni leader via Consul DNS
dig @127.0.0.1 -p 8600 primary.webitel-postgres.service.consul

# Patroni — expect 1 Leader + N Replica, Lag 0
patronictl -c /etc/patroni/config.yml list

# Nomad servers
nomad server members

# Nomad clients
nomad node status

# RabbitMQ — all nodes running
rabbitmqctl cluster_status
```

## Tags

Every role exposes fine-grained tags so you can limit execution to a specific phase:

| Tag | Effect |
|---|---|
| `base_install`, `base_repo`, `base_configure` | Base system role phases |
| `pki_ca`, `pki_node` | CA generation / per-node certificates |
| `consul_install`, `consul_configure`, `consul_dns`, `consul_queries` | Consul role phases, dnsmasq forwarding, prepared queries |
| `nomad_install`, `nomad_configure` | Nomad role phases |
| `haproxy_install`, `haproxy_configure` | HAProxy role phases |
| `postgres_install`, `postgres_configure`, `postgres_database` | Standalone PostgreSQL role phases |
| `patroni_install`, `patroni_configure`, `patroni_bootstrap` | Patroni role phases |
| `rabbitmq_install`, `rabbitmq_configure`, `rabbitmq_cluster` | RabbitMQ role phases |
| `freeswitch_install`, `freeswitch_configure` | FreeSWITCH role phases |
| `rtpengine_install`, `rtpengine_configure` | RTPEngine role phases |
| `opensips_install`, `opensips_configure`, `opensips_fail2ban` | OpenSIPS role phases |
| `nginx_install`, `nginx_configure`, `nginx_tls` | NGINX role phases |
| `grafana_install`, `grafana_configure`, `grafana_dashboards` | Grafana role phases |

Webitel services are tagged differently: one tag per service
(`webitel_core`, `webitel_engine`, `webitel_call_center`, `webitel_flow_manager`,
`webitel_storage`, `webitel_messages`, `webitel_logger`, `webitel_cases`,
`webitel_media_exporter`, `webitel_storage_key`) selects *which* services run,
and the shared `install` / `configure` tags select *which phase*. Combine them.

```bash
# Re-run only NGINX configuration
ansible-playbook -i inventories/production site.yml \
  --tags nginx_configure --ask-vault-pass

# Re-render env files for webitel_core only, without touching packages
ansible-playbook -i inventories/production site.yml \
  --tags webitel_core --skip-tags install --ask-vault-pass
```

