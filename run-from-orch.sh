#! /bin/bash

set -eu

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 [project]"
    echo
    echo "Executes Ansible in Orch(estrator) mode."
    exit 1
fi

project=$1
shift

# bin/activate references unbound variables
set +u
source bin/activate
set -u

./bin/ansible-playbook --extra-vars 'run_from_orch=true' --extra-vars 'run_from_iso=false' \
    --extra-vars "project=$project" \
    --inventory-file "$project/inventory-fixed.yaml" deployCluster.yml "$@"
