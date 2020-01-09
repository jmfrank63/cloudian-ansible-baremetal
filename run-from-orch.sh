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

# RCs get an RCxx tag in the bin file, but the staging directory and other do not cotain this
# so have an extra variable with that cleaned up version
# NOTE: DO NOT try to quote the regexp
if [[ "$hs_version" =~ RC[0-9]+ ]]; then
    # remove the RC tag
    hs_release_version="${hs_version%RC*}"
else
    hs_release_version="${hs_version}"
fi

# bin/activate references unbound variables
set +u
source bin/activate
set -u

./bin/ansible-playbook --extra-vars 'run_from_orch=true' --extra-vars 'run_from_iso=false' \
    --extra-vars "project=$project" --extra-vars "hyperstore_version=$hs_version" \
    --extra-vars "hyperstore_release_version=$hs_release_version" \
    --inventory-file "$project/inventory-fixed.yaml" --verbose deployCluster.yml "$@"
