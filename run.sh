#! /bin/bash

source bin/activate

set -eu

ansible-playbook --connection local --limit $1 --inventory-file inventory/cluster.yaml --verbose deployCluster.yml
