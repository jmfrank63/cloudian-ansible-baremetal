#! /bin/bash

set -eu

if [ $# -ne 2 ]; then
    echo "Usage: $0 [ip] [password]"
    exit 1
fi

ip=$1
password=$2
shift 2

sudo yum install -y epel-release
sudo yum install -y snapd
snap install lxd

# ip a | grep 'inet '

cat <<EOF | lxd init --preseed
config:
  core.https_address: ${ip}:8443
  core.trust_password: true
  core.trust_password: ${password}

storage_pools:
- name: local
  driver: dir
  config: {}

networks:
- name: lxdbr0
  type: bridge
  config:
    dns.mode: none
    ipv4.nat: "true"
    raw.dnsmasq: |
      dhcp-ignore-names
      local-ttl=4938790
EOF
