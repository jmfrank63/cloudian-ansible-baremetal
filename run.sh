#! /bin/bash

source bin/activate

set -eu

host=$1
shift

ansible-playbook --connection local --limit $host --inventory-file inventory/cluster.yaml --verbose deployCluster.yml "$@"
