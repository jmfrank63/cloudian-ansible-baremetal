#! /bin/bash

set -eu

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 [project] [hs_version]"
    echo
    echo "Executes Ansible in Orch(estrator) mode."
    exit 1
fi

project="$1"
hs_version="$2"
shift 2

# bin/activate references unbound variables
set +u
source bin/activate
set -u

./bin/ansible-playbook --extra-vars 'run_from_orch=true' --extra-vars 'run_from_iso=false' \
    --extra-vars "project=$project" --extra-vars "hyperstore_version=$hs_version" \
    --inventory-file "$project/inventory-fixed.yaml" --verbose deployCluster.yml "$@"
