# certbot

Obtains and auto-renews a Let's Encrypt TLS certificate for the NGINX vhost. Invoked conditionally from `playbooks/web.yml` when `nginx_tls_mode: letsencrypt`.

This role has no `defaults/main.yml`; all variables are consumed from the shared inventory scope.

The certificate is obtained with `--nginx --redirect` (HTTP → HTTPS redirect configured automatically). A monthly cron job is installed to renew certificates before expiry.
