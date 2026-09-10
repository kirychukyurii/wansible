# rabbitmq

Installs and configures RabbitMQ (single-node; cluster-ready config via Consul peer discovery).

## Variables

See `defaults/main.yml` for configurable variables.

## Tags

Tags: `rabbitmq_install`, `rabbitmq_configure` — see `tasks/main.yml`.

## Notes

- `[VM]` `files/enabled_plugins` contains `[rabbitmq_management,rabbitmq_consistent_hash_exchange]` — verify against the current `enabled_plugins` in the WEP/rabbitmq repo before deploying to production.
- Cluster mode activates automatically when `rabbitmq_cluster_hosts | length > 1`; the config uses Consul for peer discovery.
- Hostname resolution: cluster nodes talk to each other as `rabbit@<ansible_hostname>` (the server's short hostname). The role adds `/etc/hosts` entries (`<ip> <hostname>`) for all peers and pins `RABBITMQ_NODENAME=rabbit@{{ ansible_hostname }}` in `/etc/rabbitmq/rabbitmq-env.conf`.
- `[VM]` Re-running against a node previously initialized with a different NODENAME/cookie may require a manual Mnesia reset (`rabbitmqctl reset`). Not an issue on a clean install.
