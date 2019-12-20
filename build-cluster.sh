#! /bin/bash

if [ -z "$VIRTUAL_ENV" ]; then
    echo "Virtual Env not active. Please run the following: source bin/activate"
    exit 1
fi

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
ssh-add "$project/cloudian-installation-key"

(
    cd "$project"

    ln -svf ../../.terraform .
    ln -svf ../../ssh .

    terraform init
    export ANSIBLE_HOST_KEY_CHECKING=False
    terraform apply -auto-approve .
)

# rewrite with the IPs offered via DHCP
# but only onec, as TF seems to change them from time to time
# beats the purpose of a Makefile, but oh well...
if ! [ -f "$project/inventory-fixed.yaml" ]; then
    make PROJECT_DIR="$project" INFRA="$infra" "$project/inventory-fixed.yaml"
fi

./run-from-orch.sh "$project"
