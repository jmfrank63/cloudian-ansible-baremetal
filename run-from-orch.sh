#! /bin/bash

source bin/activate

set -eu

./local/bin/ansible-playbook --extra-vars 'run_from_iso=false' --inventory-file inventory/cluster.yaml --verbose deployCluster.yml "$@"
