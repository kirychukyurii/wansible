# Webitel v23.07

<!-- TOC -->
* [Webitel v23.07](#webitel-v2307)
  * [Hosts configuration](#hosts-configuration)
  * [Webitel configuration](#webitel-configuration)
  * [Run Ansible playbook for Webitel](#run-ansible-playbook-for-webitel)
    * [Localhost deployment](#localhost-deployment)
    * [Singlehost deployment](#singlehost-deployment)
    * [Custom deployment](#custom-deployment)
      * [Possible `webitel_services` values:](#possible-webitelservices-values)
<!-- TOC -->

## Hosts configuration
Declare hosts config variables in `inventories/production/group_vars/all.yml` as follows.

| Variable                       | Type   | Default | Comment                                                                                                                                      |
|--------------------------------|--------|---------|----------------------------------------------------------------------------------------------------------------------------------------------|
| `ansible_user`                 | string | -       | The user Ansible ‘logs in’ as.                                                                                                               |
| `ansible_port`                 | string | 22      | The connection port number.                                                                                                                  |
| `ansible_ssh_private_key_file` | string | -       | Private key file used by ssh. Useful if using multiple keys and you don’t want to use SSH agent (when `ansible_ssh_pass` doesn`t specified). |
| `ansible_ssh_pass`             | string | -       | The password to use to authenticate to the host (when `ansible_ssh_private_key_file` doesn`t specified).                                     |
| `ansible_become_pass`          | string | -       | Allows you to set the privilege escalation password.                                                                                         |

## Webitel configuration
Declare the Webitel config variables in `inventories/production/group_vars/all.yml` as follows.

| Variable                            | Type   | Default | Comment                                                                                                                                                                                                                                                                                                  |
|-------------------------------------|--------|---------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `webitel_repository_user`           | string | -       |                                                                                                                                                                                                                                                                                                          |
| `webitel_repository_password`       | string | -       |                                                                                                                                                                                                                                                                                                          |
| `freeswitch_signalwire_key`         | string | -       | SignalWire Personal Access Tokens (PAT) is required to install FreeSWITCH. You need to create a token and set the value in this variable. See ["How to create SignalWire Personal Access Tokens"](https://freeswitch.org/confluence/display/FREESWITCH/HOWTO+Create+a+SignalWire+Personal+Access+Token). |
| `rtpengine_mode`                    | string | -       | `global`, `local`.                                                                                                                                                                                                                                                                                       |
| `opensips_fail2ban`                 | bool   | false   | Whether ban attackers after they have tried to login with wrong authentication credentials.                                                                                                                                                                                                              |
| `nginx_letsencrypt`                 | bool   | false   | Enable automatically get an SSL certificate. Require valid FQDN name.                                                                                                                                                                                                                                    |
| `nginx_site_name`                   | string | -       | FQDN name to obtain a certificate.                                                                                                                                                                                                                                                                       |
| `nginx_mail_address`                | string | -       | Existing email address.                                                                                                                                                                                                                                                                                  |
| `grafana_enable`                    | bool   | false   | Install Grafana to build analytics based on database data.                                                                                                                                                                                                                                               |
| `grafana_basic_dashboards`          | bool   | false   | Import basic dashboards to Grafana. See ["A set of common dashboards"](https://docs.webitel.com/x/Gwo7Cg).                                                                                                                                                                                               |
| `grafana_basic_dashboards_language` | string | -       | Set language for basic dashboards. Possible values: `en`.                                                                                                                                                                                                                                                |

## Run Ansible playbook for Webitel

### Localhost deployment
	./deploy.sh -i inventories/production/localhost.yml playbook.yml

### Singlehost deployment
	./deploy.sh -i inventories/production/singlehost.yml playbook.yml

Before running playbook on a single host deployment please edit your inventory `inventories/production/singlehost.yml` or setup server access in `inventories/production/group_vars/all.yml`

### Custom deployment
	./deploy.sh -i inventories/production/custom.yml playbook.yml

Before running playbook with custom services definition please edit your inventory `inventories/production/custom.yml` and setup list of services (variable `webitel_services`) that would be installed.

#### Possible `webitel_services` values:
| Name                   | Required | Comment                                                            | Limits                                                                                               |
|------------------------|----------|--------------------------------------------------------------------|------------------------------------------------------------------------------------------------------|
| `consul`               | true     | Install and configure Consul.                                      | Only one concurrent.                                                                                 |
| `rabbitmq`             | true     | Install and configure RabbitMQ.                                    | Only one concurrent.                                                                                 |
| `postgresql`           | true     | Install and configure PostgreSQL.                                  | Must be added to all hosts with DB (main or standby).                                                |
| `postgresql_main`      | true     | Configure main PostgreSQL DB.                                      | Only one concurrent.                                                                                 |
| `postgresql_standby`   | false    | Configure standby PostgreSQL DB.                                   | -                                                                                                    |
| `freeswitch`           | true     | Install and configure Freeswitch.                                  | -                                                                                                    |
| `rtpengine`            | true     | Install and configure RTPEngine.                                   | Only one concurrent. Basically, installed on host which accessible from Internet (have a public IP). |
| `opensips`             | true     | Install and configure OpenSIPs.                                    | Only one concurrent. Basically, installed on host which accessible from Internet (have a public IP). |
| `nginx`                | true     | Install and configure NGINX.                                       | Only one concurrent. Basically, installed on host which accessible from Internet (have a public IP). |
| `webitel_core`         | true     | Install and configure `webitel-api`, `webitel-app`, `webitel-uac`. | -                                                                                                    |
| `webitel_engine`       | true     | Install and configure `webitel-engine`.                            | -                                                                                                    |
| `webitel_call_center`  | true     | Install and configure `webitel-call-center`.                       | -                                                                                                    |
| `webitel_flow_manager` | true     | Install and configure `webitel-flow-manager`.                      | -                                                                                                    |
| `webitel_storage`      | true     | Install and configure `webitel-storage`.                           | -                                                                                                    |
| `webitel_messages`     | false    | Install and configure `webitel-messages`.                          | -                                                                                                    |