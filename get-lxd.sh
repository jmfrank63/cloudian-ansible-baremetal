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
# for some reason the service is not started, so do it by hand
sudo systemctl enable --now snapd.socket
sudo snap install lxd

# this should be solved the next time the user logs in, altho we don't particularlly care
# export PATH=$PATH:/var/liv/snapd/snap/bin

cat <<EOF | sudo /var/liv/snapd/snap/bin/lxd init --preseed
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
