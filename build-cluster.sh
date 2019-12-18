#! /bin/bash

set -eu

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 [project_dir] [infra]"
    exit 1
fi

project="$1"
main_file="$project/main.yaml"

if ! [ -f "$main_file" ]; then
    echo "Clould not find main file '$main_file' in project dir '$project', bailing out!"
    exit 1
fi

infra="$2"

if [ -f "$infra" ]; then
    # it's passing the file with the infra, we need the name, let's see if we can get it
    infra="${infra#infra/}"  # remove leading infra/
    infra="${infra%.yaml}"   # remove trailing .yaml
fi

if ! [ -f "infra/${infra}.yaml" ]; then
    echo "Cloud not find infra file '$infra', bailing out!"
    exit 1
fi

make PROJECT_DIR="$project" INFRA="$infra"

(
    cd "$project"

    ln -svf ../../.terraform .
    ln -svf ../../ssh .

    terraform init
    export ANSIBLE_HOST_KEY_CHECKING=False
    terraform apply -auto-approve .
)

# update
make PROJECT_DIR="$project" INFRA="$infra" "$project/inventory-fixed.yaml"

./run-from-orch.sh "$project"
