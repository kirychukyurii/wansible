# Patroni Warm-Standby 2-DC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Commit policy (project convention):** Do NOT `git commit`/`git push` without explicit user approval. Commit steps below are part of the recipe — pause and ask before running them.

**Goal:** Make the standby datacenter (`dc_b`) bootstrap its Patroni cluster as a *standby cluster* that streams from the primary datacenter (`dc_a`), instead of coming up as a second independent primary.

**Architecture:** Each DC keeps its own isolated Consul DCS and its own Patroni cluster (same `scope`, safe because the two Consul DCs are not federated). The standby DC's Patroni gets a `standby_cluster` block in `bootstrap.dcs` whose `host` is the **comma-separated list of all primary-DC Patroni node IPs**. Per Patroni docs, a multi-host `standby_cluster.host` makes Patroni inject `target_session_attrs=read-write` into `primary_conninfo`, so libpq always connects to whichever source node is the actual primary and re-finds it after a primary-DC failover — native leader-following, no extra proxy. `pg_rewind` prerequisites are already met (the `initdb` block uses `data-checksums` and `use_pg_rewind: true`). No HAProxy for the source, no replication slot (warm-standby; accept full rebuild on extreme lag), no live promotion step (out of scope).

**Tech Stack:** Ansible, Patroni, Consul (DCS), PostgreSQL 15/18.

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `roles/topology/tasks/main.yml` | Derive cluster facts | Add `patroni_is_standby_dc`, `_topology_patroni_primary_hosts`; extend dependency assert (T1) |
| `roles/patroni/defaults/main.yml` | Patroni inputs | Add `patroni_is_standby`, `patroni_standby_cluster_host` (comma IP list), `patroni_standby_cluster_port` |
| `roles/patroni/templates/patroni.yml.j2` | Patroni config | Add conditional `standby_cluster` block; widen replication `pg_hba` to all DCs |
| `playbooks/preflight.yml` | Validation gate | Add P1 (multi-DC Patroni requires `primary_datacenter`) |
| `inventories/warm-standby-2dc.example/group_vars/all/main.yml` | Example input | Add `primary_datacenter: dc_a` |

**Note — no HAProxy in this design.** An earlier revision routed the standby source through a local HAProxy source-listener. Patroni's native multi-host `standby_cluster.host` (with auto `target_session_attrs=read-write`) makes that unnecessary: it removes a daemon, the role-ordering constraint, the `webitel_pg_haproxy` global-flag side-effect, and the per-node sidecar requirement. The warm-standby example keeps its existing Consul-DNS app addressing unchanged.

---

## Task 1: Topology facts for standby designation

**Files:**
- Modify: `roles/topology/tasks/main.yml`

- [ ] **Step 1: Add `patroni_is_standby_dc` to the topology-flags step**

In `roles/topology/tasks/main.yml`, the task `Resolve topology flags` (`set_fact` with `single_node`/`ha_mode`/...), add one key. `primary_datacenter` is an optional input (undefined in single-DC inventories) so default safely to "not a standby":

```yaml
- name: Resolve topology flags
  ansible.builtin.set_fact:
    single_node: "{{ (groups['all'] | default([])) | length == 1 }}"
    ha_mode: "{{ (groups['patroni'] | default([])) | length > 0 }}"
    webitel_pg_haproxy: "{{ (groups['haproxy'] | default([])) | length > 0 }}"
    webitel_release_component: "{{ webitel_version }}-releases"
    patroni_is_standby_dc: >-
      {{ (primary_datacenter is defined) and (datacenter != primary_datacenter) }}
```

- [ ] **Step 2: Add the primary-DC Patroni host list to the per-DC step**

In the task `Resolve per-datacenter host lists`, add `_topology_patroni_primary_hosts` (Patroni nodes of the primary DC; falls back to own DC when `primary_datacenter` is unset, harmless because it is only consumed when `patroni_is_standby_dc` is true):

```yaml
    _topology_patroni_primary_hosts: >-
      {{ groups['patroni'] | default([]) | map('extract', hostvars)
         | selectattr('datacenter', 'defined')
         | selectattr('datacenter', '==', primary_datacenter | default(datacenter))
         | map(attribute='inventory_hostname') | list }}
```

- [ ] **Step 3: Extend the dependency-source assert (T1)**

In the task `Assert dependency sources are resolvable`, add one line to `that:` — on a standby DC the primary-DC source cluster must be resolvable:

```yaml
      - not (patroni_is_standby_dc | bool) or (_topology_patroni_primary_hosts | length > 0)
```

- [ ] **Step 4: Lint**

Run: `ansible-lint roles/topology`
Expected: no new violations.

- [ ] **Step 5: Commit** (ask first — see commit policy)

```bash
git add roles/topology/tasks/main.yml
git commit -m "feat(topology): derive patroni_is_standby_dc and primary-DC host list"
```

---

## Task 2: Patroni standby_cluster block + cross-DC pg_hba

**Files:**
- Modify: `roles/patroni/defaults/main.yml`
- Modify: `roles/patroni/templates/patroni.yml.j2`

- [ ] **Step 1: Add standby defaults**

Append to `roles/patroni/defaults/main.yml`. `patroni_standby_cluster_host` is the comma-joined list of primary-DC node IPs; Patroni injects `target_session_attrs=read-write` when it sees multiple hosts, so the standby leader follows the real primary across failover. A single `port` applies to all listed hosts.

```yaml
# Warm-standby: на нодах standby-ДЦ Patroni піднімається як standby_cluster і
# стрімить з primary-ДЦ. host = кома-список IP усіх patroni-нод primary-ДЦ —
# Patroni додає target_session_attrs=read-write, тож libpq сам тримається
# справжнього лідера primary (і слідкує за failover там). Слот не використовуємо.
patroni_is_standby: "{{ patroni_is_standby_dc | default(false) }}"
patroni_standby_cluster_host: >-
  {{ _topology_patroni_primary_hosts | default([])
     | map('extract', hostvars, ['ansible_default_ipv4', 'address'])
     | join(',') }}
patroni_standby_cluster_port: 5432
```

- [ ] **Step 2: Add the conditional `standby_cluster` block**

In `roles/patroni/templates/patroni.yml.j2`, inside `bootstrap.dcs`, insert immediately after the `maximum_lag_on_failover: 1048576` line:

```jinja
    maximum_lag_on_failover: 1048576
{% if patroni_is_standby | bool %}
    standby_cluster:
      host: {{ patroni_standby_cluster_host }}
      port: {{ patroni_standby_cluster_port }}
      create_replica_methods:
        - basebackup
{% endif %}
```

(`pg_rewind` prerequisite is already satisfied: the existing `initdb` block has `- data-checksums` and `postgresql.use_pg_rewind: true` — no change needed.)

- [ ] **Step 3: Widen replication pg_hba to all Patroni nodes**

Replace the existing per-cluster loop (currently emits both `host all all` and `host replication` for `patroni_cluster_hosts`) with: `host all all` for the local cluster, and `host replication` for **all** Patroni nodes across DCs (so the standby leader in `dc_b` may connect to `dc_a`, and vice-versa for a future reverse direction).

Old:
```jinja
{% for h in patroni_cluster_hosts %}
    - host all all {{ hostvars[h].ansible_default_ipv4.address }}/32 scram-sha-256
    - host replication {{ patroni_replication_user }} {{ hostvars[h].ansible_default_ipv4.address }}/32 scram-sha-256
{% endfor %}
```

New:
```jinja
{% for h in patroni_cluster_hosts %}
    - host all all {{ hostvars[h].ansible_default_ipv4.address }}/32 scram-sha-256
{% endfor %}
{% for h in groups['patroni'] | default([]) %}
    - host replication {{ patroni_replication_user }} {{ hostvars[h].ansible_default_ipv4.address }}/32 scram-sha-256
{% endfor %}
```

- [ ] **Step 4: Lint + syntax check**

Run: `ansible-lint roles/patroni`
Expected: no new violations.

Run: `ansible-playbook playbooks/database.yml -i inventories/warm-standby-2dc.example --syntax-check`
Expected: no errors. Note: `--syntax-check` does NOT evaluate Jinja in templates — full render is verified in Task 5 on the VM env.

- [ ] **Step 5: Commit** (ask first)

```bash
git add roles/patroni/defaults/main.yml roles/patroni/templates/patroni.yml.j2
git commit -m "feat(patroni): standby_cluster (multi-host source) on standby DC + cross-DC replication pg_hba"
```

---

## Task 3: Preflight validation (P1)

**Files:**
- Modify: `playbooks/preflight.yml`

- [ ] **Step 1: Add P1 in the cross-host (`hosts: localhost`) play**

In `playbooks/preflight.yml`, in the second play (`Preflight topology checks (cross-host)`), insert after the existing task `Preflight | Patroni cluster must not span datacenters ...`:

```yaml
    - name: Preflight | Multi-DC Patroni requires primary_datacenter (else each DC is an independent primary)
      ansible.builtin.assert:
        that: >-
          (groups['patroni'] | default([]) | map('extract', hostvars)
           | map(attribute='datacenter') | unique | list | length) <= 1
          or (primary_datacenter is defined
              and primary_datacenter in (groups['patroni'] | default([])
                  | map('extract', hostvars)
                  | map(attribute='datacenter') | unique | list))
        fail_msg: >-
          Patroni spans multiple datacenters but primary_datacenter is unset or
          is not one of them. Without it each DC bootstraps as an INDEPENDENT
          primary (no cross-DC replication). Set primary_datacenter to the
          replication-source datacenter (e.g. primary_datacenter: dc_a).
        quiet: true
```

- [ ] **Step 2: Verify the assert FAILS on the current (unmodified) example**

The example still lacks `primary_datacenter`, so the assert should fire. Run only the localhost play (no host connections needed; the assert reads inventory vars):

Run: `ansible-playbook playbooks/preflight.yml -i inventories/warm-standby-2dc.example --limit localhost`
Expected: FAIL on `Multi-DC Patroni requires primary_datacenter` (the first play `hosts: all` is skipped because no inventory host matches `--limit localhost`).

- [ ] **Step 3: Commit** (ask first)

```bash
git add playbooks/preflight.yml
git commit -m "feat(preflight): require primary_datacenter for multi-DC Patroni"
```

---

## Task 4: Update warm-standby example inventory (turns preflight green)

**Files:**
- Modify: `inventories/warm-standby-2dc.example/group_vars/all/main.yml`

- [ ] **Step 1: Declare the primary datacenter**

In `inventories/warm-standby-2dc.example/group_vars/all/main.yml`, in the `--- Warm-standby 2-DC overrides ---` block, add:

```yaml
# Designates the replication-source DC. dc_b bootstraps its Patroni as a
# standby_cluster streaming from dc_a (multi-host primary_conninfo).
primary_datacenter: dc_a
```

(No `haproxy` service additions — this design does not use HAProxy for the standby source.)

- [ ] **Step 2: Verify preflight now PASSES**

Run: `ansible-playbook playbooks/preflight.yml -i inventories/warm-standby-2dc.example --limit localhost`
Expected: all assert tasks `ok`; play recap shows `failed=0`.

- [ ] **Step 3: Commit** (ask first)

```bash
git add inventories/warm-standby-2dc.example/group_vars/all/main.yml
git commit -m "feat(inventory): warm-standby example designates primary_datacenter"
```

---

## Task 5: Integration verification on the 2-DC VM env

**Files:** none (verification only). Requires the OrbStack/VM 2-DC environment (see memory `project_orbstack_test_env`).

- [ ] **Step 1: Full deploy against the warm-standby inventory**

Run: `ansible-playbook playbooks/database.yml -i <orbstack-warm-standby-inventory>`
Expected: completes without errors; `dc_a` forms first (serial:1 inventory order), then `dc_b` nodes bootstrap from it.

- [ ] **Step 2: Confirm dc_a is a normal primary cluster**

On a `dc_a` node:
Run: `patronictl -c /etc/patroni/patroni.yml list`
Expected: roles are `Leader` + `Replica` (no "Standby Leader").

- [ ] **Step 3: Confirm dc_b is a standby cluster**

On a `dc_b` node:
Run: `patronictl -c /etc/patroni/patroni.yml list`
Expected: the leader row shows role **`Standby Leader`**; others `Replica`.

- [ ] **Step 4: Confirm dc_b replicates from dc_a's primary with the right conninfo**

On the `dc_b` standby leader:
Run: `sudo -u postgres psql -tAc "select pg_is_in_recovery();"`
Expected: `t` (in recovery → following dc_a).

Run: `sudo -u postgres psql -tAc "select conninfo from pg_stat_wal_receiver;"`
Expected: conninfo lists all dc_a node IPs and contains `target_session_attrs=read-write`; the active connection is dc_a's current primary.

- [ ] **Step 5: Confirm cross-DC failover tracking**

Trigger a switchover in `dc_a` (`patronictl switchover`), then re-check the `dc_b` standby leader.
Expected: `pg_is_in_recovery()` stays `t`, and `pg_stat_wal_receiver` now shows the NEW dc_a primary IP — proving libpq's `target_session_attrs=read-write` re-finds the primary after failover, with no Ansible re-run.

---

## Self-Review Notes

- **Spec coverage:** standby_cluster block (T2), primary/standby designation (T1+T4), source endpoint = native multi-host conninfo (T2), cross-DC pg_hba (T2), pg_rewind prereq already met (data-checksums in template), no slot (omitted by design), scope unchanged (no assert — isolated DCS confirmed), validation P1 + T1 (T1+T3), inventory example (T4), integration (T5). All agreed spec items covered.
- **Type/name consistency:** `patroni_is_standby_dc` (topology fact) → consumed by `patroni_is_standby` (patroni default). `_topology_patroni_primary_hosts` (topology fact) → consumed by `patroni_standby_cluster_host` (joined to IP CSV) and T1 assert. `primary_datacenter` used identically in topology, preflight, and inventory.
- **Dropped vs earlier revision:** HAProxy source-listener, haproxy-on-all-nodes, database.yml reorder, preflight P3 — all removed; superseded by Patroni native multi-host `standby_cluster.host`.
- **Deferred:** live promotion (remove `standby_cluster` via REST/`patronictl edit-config`) and replication slot — both intentionally out of scope.
