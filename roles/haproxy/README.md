# haproxy

HAProxy in front of the Patroni PostgreSQL cluster and the RabbitMQ cluster.
Backends come from **Consul service discovery** (`resolvers` + `server-template`),
directly from Consul DNS (`127.0.0.1:8600`, not via dnsmasq).

TCP listeners:
- `postgres-rw` (`:6432`) → leader (`primary.<scope>.service.consul`)
- `postgres-ro` (`:6433`) → replicas, roundrobin (`replica.<scope>.service.consul`)
- `rabbitmq-amqp` (`:5673`) → rabbitmq nodes, leastconn (`rabbitmq.service.consul`)

Patroni determines PG node role via Consul tags (`primary`/`replica`); rabbitmq
uses Consul peer discovery (TTL heartbeat). HAProxy adds load balancing, a stable
local socket, and its own TCP check; backend membership stays in sync with Consul's verdict.

PG listeners render when `haproxy_backends` is present, AMQP when
`haproxy_rabbitmq_backends` is present.

## Topology
- **sidecar** — `haproxy` in `services` on each app host; services connect via `127.0.0.1`.
- **dedicated** — `haproxy` on a single host; services connect via its IP.

`webitel_pg_*` / `webitel_amqp_*` are computed in topology based on whether the
`haproxy` group exists. preflight requires PG/AMQP consumers to have a local haproxy.

See `defaults/main.yml` for configurable variables.

## Dependencies
A Consul agent with DNS on `:8600`; Patroni and RabbitMQ services registered in Consul.
