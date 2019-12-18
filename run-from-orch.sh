#! /bin/bash

set -eu
project=$1
shift

# bin/activate references unbound variables
set +u
source bin/activate
set -u


./bin/ansible-playbook --extra-vars 'run_from_orch=true' --extra-vars 'run_from_iso=false' \
    --inventory-file "$project/inventory-fixed.yaml" deployCluster.yml "$@"
