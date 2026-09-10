# consul

Installs and configures HashiCorp Consul (server mode) via the official HashiCorp APT repository.

See `defaults/main.yml` for configurable variables.

## Datacenter scope

`consul_datacenter` follows the deployment profile (see `roles/topology/vars/main.yml`):

- `_topology_db_scope: dc` (default) — each site is its own isolated Consul datacenter, named after `datacenter`. No WAN federation.
- `_topology_db_scope: global` (profile `stretch`) — all sites form ONE Consul datacenter named `consul_global_datacenter`, with a single raft whose servers sit in exactly three fault domains. `consul_raft_multiplier` widens the heartbeat and leader-lease windows accordingly (5 vs the LAN default of 1); tune it down once the real inter-site RTT is measured.
