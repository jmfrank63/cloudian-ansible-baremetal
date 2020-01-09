#! /bin/bash

if [ -z "$VIRTUAL_ENV" ]; then
    echo "Virtual Env not active. Please run the following: source bin/activate"
    exit 1
fi

if [ -z "$SSH_AUTH_SOCK" ]; then
    echo "Could not find a running ssh-agent, please run: ssh-agent bash"
    echo "and try again."
    exit 1
fi

set -eu

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 [project] [hs_version] [ansible_args ...]"
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

# TODO: rm -f /opt/cloudian-staging/7.2/cloudian-installation.log /opt/cloudian-staging/7.2/CloudianInstallConfiguration.txt
# for forece reinstall

# because we're creating and destroying nodes en masse, a new node having
# the same IP as a previous node but different HOstKey is bound to happen

# so we just use a discardbale known_hosts file

# and we just discard it now
rm --force "$project/know_hosts"

./bin/ansible-playbook --extra-vars 'run_from_orch=true' --extra-vars 'run_from_iso=false' \
    --extra-vars "project=$project" --extra-vars "hyperstore_version=$hs_version" \
    --extra-vars "hyperstore_release_version=$hs_release_version" \
    --inventory-file "$project/inventory-fixed.yaml" \
    --ssh-common-args "-o ForwardAgent=yes -o UserKnownHostsFile=$project/know_hosts" \
    "$@" --verbose deployCluster.yml
