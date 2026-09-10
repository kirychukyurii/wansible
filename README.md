<div align="center">
  <h2>
    Webitel 26.4
  </h2>

  <a href="https://github.com/kirychukyurii/wansible/actions?query=workflow%3Areviewdog+event%3Apush+branch%3Amain">
    <img alt="GitHub Actions (lint)" src="https://github.com/kirychukyurii/wansible/workflows/reviewdog/badge.svg?branch=main&event=push">
  </a>
</div>

<!-- TOC -->
  * [Requirements](#requirements)
  * [Quickstart](#quickstart)
  * [HA deployment](#ha-deployment)
  * [Inventory model](#inventory-model)
  * [Services](#services)
  * [Key variables](#key-variables)
  * [Tags](#tags)
  * [Vault usage](#vault-usage)
<!-- TOC -->

## Requirements

- **Ansible controller:** ansible-core >= 2.16, collections from `requirements.yml`
- **Target OS:** Debian 12 (bookworm) or Debian 13 (trixie), amd64
  - Hosts running `postgres` or `freeswitch` **must** be amd64 (packages are amd64-only)
- **Access:** SSH key or password, sudo/become rights on target hosts
- **Credentials:** Webitel S3 APT repository keys (access + secret), SignalWire Personal Access Token for FreeSWITCH

## Quickstart

```bash
# 1. Install required Ansible collections
ansible-galaxy collection install -r requirements.yml

# 2. Create your inventory from the example
cp -r inventories/singlehost.example inventories/production

# 3. Edit host definitions and assign services
$EDITOR inventories/production/01-hosts.yml

# 4. Fill in secret credentials
cp inventories/production/group_vars/all/vault.yml.example \
   inventories/production/group_vars/all/vault.yml
$EDITOR inventories/production/group_vars/all/vault.yml
ansible-vault encrypt inventories/production/group_vars/all/vault.yml

# 5. Run the playbook
ansible-playbook -i inventories/production site.yml --ask-vault-pass
```

For a multi-host deployment use `inventories/multihost.example` as the starting template instead.

## Deployment profiles

Every inventory declares what it is via `topology_profile` in
`group_vars/all/main.yml`. Preflight refuses to run when the inventory does not match
the declared profile, so unsupported shapes fail before the first package is installed.

| `topology_profile` | Datacenters | PostgreSQL | Consul | RabbitMQ / Nomad | Promotion |
|---|---|---|---|---|---|
| `singlehost` | 1 (one host) | standalone | 1 server, loopback | single | — |
| `multihost` | 1 | standalone | 1 server | single | — |
| `failover` | 1 | one Patroni cluster | 1 cluster, 3+, odd | cluster | Patroni, within the DC |
| `warm_standby` | 2+ | primary cluster + N standby clusters | isolated cluster per DC | per DC | external controller |
| `stretch` | 3+ | one cluster across all DCs | one raft over three fault domains | per DC | Patroni, automatic |

Host and datacenter counts are not part of the profile: `warm_standby` is N datacenters,
not two. At three datacenters both `warm_standby` and `stretch` are available — the
profile name is the choice, it is never inferred from the inventory.

`stretch` is active/passive: traffic is served by the datacenter holding the database
leader. It widens Consul and Patroni raft timings automatically (`consul_raft_multiplier`,
`patroni_ttl`, `patroni_retry_timeout`); set `patroni_synchronous_mode: true` if a
cross-DC failover must not lose transactions, at the cost of a WAN round trip per commit.

Two datacenters without replication between them is not a profile: that is two separate
`failover` installations, and they belong in two inventories.

All profiles use the same `site.yml` playbook; the inventory's constructed groups
(`consul_server`, `patroni`, `nomad_server`, `rabbitmq`) determine cluster vs. single-node
behavior automatically.

Validate an inventory without touching any host:

```bash
ansible-playbook -i inventories/<name> playbooks/validate_topology.yml
```

Design rationale: `docs/superpowers/specs/2026-09-10-topology-profiles-design.md`.

#### Failover (1-DC, single cluster)

DCS=Consul for the Patroni cluster. See `inventories/failover.example/01-hosts.yml` for the
full host/service mapping.

#### Warm standby (2-DC, per-DC clusters)

Each datacenter (`dc_a`, `dc_b`) runs its own isolated Consul, Patroni, Nomad, and RabbitMQ
cluster. The datacenter named by `primary_datacenter` bootstraps the primary Patroni cluster;
every other datacenter brings its Patroni up as a `standby_cluster` streaming from it, using
the primary DC's node IPs directly (Patroni adds `target_session_attrs=read-write`, so it
follows the real leader across a failover inside the primary DC). Replication is asynchronous
and holds no replication slot: on extreme lag the standby is rebuilt.

Promoting the standby datacenter is **not** done by this playbook — that belongs to Nomad jobs
and the external controller. RabbitMQ is not federated across datacenters.

`inventories/warm-standby-2dc.example` lays out a full HA topology, 12 nodes per DC:

| Node | Services |
|---|---|
| `nginx` | nginx, grafana, webitel_frontend, haproxy |
| `sip` | opensips |
| `rtp` | rtpengine |
| `switch` | freeswitch, webitel_flow_manager, haproxy |
| `storage` | webitel_storage, haproxy |
| `db1`-`db3` | patroni (priority 3/2/1) |
| `mq1`-`mq3` | rabbitmq, consul_server, nomad_server |
| `app` | webitel_core, webitel_engine, webitel_call_center, webitel_messages, haproxy |

`consul_agent` and `nomad_client` run on every node except `mq*` (server mode there); `haproxy`
runs on any node that talks to Postgres or RabbitMQ.

> **Note:** Nomad jobs are not deployed by this playbook (phase 3). The clusters are brought up
> and registered in Consul; job scheduling is a separate step.

### Generating secrets

Before running the playbook populate the vault file with HA-specific secrets.
All values go into `inventories/production/group_vars/all/vault.yml` (encrypted with
`ansible-vault`).

```bash
# Consul gossip encryption key (16-byte base64)
consul keygen
# -> paste result as vault_consul_encrypt_key

# Erlang cookie for RabbitMQ cluster (any long random string)
openssl rand -hex 32
# -> paste result as vault_rabbitmq_erlang_cookie

# Patroni passwords — generate one per variable
openssl rand -hex 16   # vault_patroni_superuser_password
openssl rand -hex 16   # vault_patroni_replication_password
openssl rand -hex 16   # vault_patroni_rewind_password
openssl rand -hex 16   # vault_patroni_restapi_password
```

Minimal vault file for HA (`vault.yml.example` in each HA example inventory lists all keys):

```yaml
vault_consul_encrypt_key: "<consul keygen output>"
vault_rabbitmq_erlang_cookie: "<random string, same on all nodes>"
vault_patroni_superuser_password: "<random>"
vault_patroni_replication_password: "<random>"
vault_patroni_rewind_password: "<random>"
vault_patroni_restapi_password: "<random>"
# Plus the standard phase-1 secrets:
vault_webitel_repo_s3_access_key: "..."
vault_webitel_repo_s3_secret_key: "..."
vault_freeswitch_signalwire_key: "..."
```

### Bring-up order

`site.yml` runs plays in this sequence:

1. PKI (CA + node certificates, controller-side)
2. Base system
3. Consul servers (serial: 1)
4. Consul agents
5. Nomad servers, then Nomad clients
6. Patroni cluster (serial: 1)
7. RabbitMQ cluster (serial: 1)
8. Webitel application services

Run the playbook once:

```bash
ansible-playbook -i inventories/production site.yml --ask-vault-pass
```

For a 2-DC warm-standby deployment use `inventories/warm-standby-2dc.example` as the template:

```bash
cp -r inventories/warm-standby-2dc.example inventories/production
$EDITOR inventories/production/01-hosts.yml   # fill in real IPs and datacenter labels
ansible-vault encrypt inventories/production/group_vars/all/vault.yml
ansible-playbook -i inventories/production site.yml --ask-vault-pass
```

### Verification commands

After a successful run, confirm cluster health on any cluster node:

```bash
# Consul — all servers should be alive
consul members

# Resolve the Patroni leader via Consul DNS
dig @127.0.0.1 -p 8600 master.webitel-postgres.service.consul

# Patroni — expect 1 Leader + N Replica, Lag 0
patronictl -c /etc/patroni/config.yml list

# Nomad servers
nomad server members

# Nomad clients
nomad node status

# RabbitMQ — all nodes running
rabbitmqctl cluster_status
```

## Inventory model

Webitel 26.4 uses a **host-centric** inventory: each host declares a `services` list, and
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

Inspect the resulting groups at any time:

```bash
ansible-inventory -i inventories/production --graph
```

## Services

The table below lists every supported service value for the `services` host variable.

| Service | Description |
|---|---|
| `consul_server` | HashiCorp Consul (server mode, service discovery) |
| `postgres` | PostgreSQL + TimescaleDB + Webitel extension |
| `rabbitmq` | RabbitMQ message broker |
| `freeswitch` | FreeSWITCH media server |
| `rtpengine` | Sipwise RTPEngine (media relay) |
| `opensips` | OpenSIPS SIP proxy |
| `nginx` | NGINX reverse proxy (and optional Let's Encrypt) |
| `grafana` | Grafana analytics and dashboards |
| `webitel_core` | Webitel API, App and UAC services |
| `webitel_engine` | Webitel Engine (call routing) |
| `webitel_call_center` | Webitel Call Center service |
| `webitel_flow_manager` | Webitel Flow Manager (IVR / dialplan) |
| `webitel_storage` | Webitel Storage (recordings, files) |
| `webitel_messages` | Webitel Messages (chat channels) |
| `webitel_logger` | Webitel Logger (audit log) |
| `webitel_cases` | Webitel Cases (CRM cases) |
| `webitel_media_exporter` | Webitel Media Exporter (recording export) |
| `webitel_frontend` | Webitel frontend web applications |

## Key variables

Set these in `inventories/production/group_vars/all.yml` (plain values) and
`inventories/production/group_vars/all/vault.yml` (secrets, encrypted with `ansible-vault`).

| Variable | Default | Description |
|---|---|---|
| `webitel_version` | `"26.4"` | Webitel release version |
| `webitel_repo_s3_access_key` | — (required) | S3 APT repo AWS AccessKeyId |
| `webitel_repo_s3_secret_key` | — (required) | S3 APT repo AWS SecretAccessKey |
| `webitel_repo_s3_bucket` | `webitel-apt-repo` | S3 bucket name |
| `webitel_repo_s3_region` | `eu-central-1` | S3 region |
| `freeswitch_signalwire_key` | — (required) | SignalWire Personal Access Token |
| `nginx_letsencrypt` | `false` | Enable Let's Encrypt TLS certificate |
| `nginx_site_name` | `webitel.example.com` | Public FQDN for NGINX and Let's Encrypt |
| `nginx_mail_address` | `cloud@example.com` | Email address for Let's Encrypt registration |
| `rtpengine_mode` | `global` | `global` (public IP via ipify) or `local` |
| `grafana_basic_dashboards` | `false` | Import pre-built Grafana dashboards |
| `grafana_basic_dashboards_language` | `en` | Dashboard language (`en`) |
| `datacenter` | `dc1` | Consul datacenter name |

### HTTP proxy (install-time)

If internet access goes through a corporate proxy, set these in the inventory's
`group_vars/all`:

```yaml
http_proxy:  "http://proxy.example.com:3128"
https_proxy: "http://proxy.example.com:3128"   # optional; defaults to http_proxy
proxy_no_proxy_extra: []                          # optional
```

Applies only to the install phase (apt, GPG key downloads, apt-transport-s3). `no_proxy` is
built automatically (`localhost`, `.consul`, all cluster host IPs). Leave unset for direct
internet access.

## Tags

Every role exposes fine-grained tags so you can limit execution to a specific phase:

| Tag pattern | Effect |
|---|---|
| `base_install`, `base_repo`, `base_configure` | Base system role phases |
| `consul_install`, `consul_configure` | Consul role phases |
| `postgres_install`, `postgres_configure`, `postgres_database` | PostgreSQL role phases |
| `rabbitmq_install`, `rabbitmq_configure` | RabbitMQ role phases |
| `freeswitch_install`, `freeswitch_configure` | FreeSWITCH role phases |
| `rtpengine_install`, `rtpengine_configure` | RTPEngine role phases |
| `opensips_install`, `opensips_configure`, `opensips_fail2ban` | OpenSIPS role phases |
| `nginx_install`, `nginx_configure` | NGINX role phases |
| `grafana_install`, `grafana_configure`, `grafana_dashboards` | Grafana role phases |
| `webitel_*_install`, `webitel_*_configure` | Per-service Webitel role phases |

Example — re-run only configuration for nginx and webitel_core:

```bash
ansible-playbook -i inventories/production site.yml \
  --tags nginx_configure,webitel_core_configure --ask-vault-pass
```

## Vault usage

Sensitive values (S3 credentials, SignalWire key) must be stored in an encrypted vault file.

```bash
# Encrypt the vault file
ansible-vault encrypt inventories/production/group_vars/all/vault.yml

# Edit encrypted vault
ansible-vault edit inventories/production/group_vars/all/vault.yml

# Run playbook with vault password prompt
ansible-playbook -i inventories/production site.yml --ask-vault-pass

# Or use a password file (do not commit it)
ansible-playbook -i inventories/production site.yml --vault-password-file ~/.vault_pass
```

See `inventories/singlehost.example/group_vars/all/vault.yml.example` for the list of required vault variables.
