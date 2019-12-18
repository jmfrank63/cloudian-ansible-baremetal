#! /bin/bash

source bin/activate

set -eu

host=$1
shift

ansible-playbook --connection local --limit $host \
    --extra-vars 'run_from_iso=true' --extra-vars 'run_from_orch=true' \
    --inventory-file inventory/cluster.yaml --verbose deployCluster.yml "$@"
