#! /bin/bash

if [ -z "$VIRTUAL_ENV" ]; then
    echo "Virtual Env not active. Please run the following: source bin/activate"
    exit 1
fi

set -eu

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 [project]"
    echo
    echo "Destroys the cluster associated to project."
    exit 1
fi

project=$1

(
    cd $project
    terraform destroy -auto-approve .
    # this is generated, and next time we build this cluster, IPs will be different
    rm -f inventory-fixed.yaml
)
