#! /bin/bash

set -eu

if [ "${1:-}" == '--restart' ];  then
    rm -f terraform_0.11.15-oci_linux_amd64.zip
    rm -f terraform-provider-lxd_v1.2.0_linux_amd64.zip
    rm -f versions.tf
    rm -rf .terraform
fi

# wget https://releases.hashicorp.com/terraform/0.12.2/terraform_0.12.2_linux_amd64.zip
# unzip terraform_0.12.2_linux_amd64.zip
wget https://releases.hashicorp.com/terraform/0.11.15-oci/terraform_0.11.15-oci_linux_amd64.zip
unzip terraform_0.11.15-oci_linux_amd64.zip

mv terraform bin/

# we have to do this because tf doesn't know anything about tf-lxd
# otherwise tf init would be enough
wget https://github.com/sl1pm4t/terraform-provider-lxd/releases/download/v1.2.0/terraform-provider-lxd_v1.2.0_linux_amd64.zip
unzip terraform-provider-lxd_v1.2.0_linux_amd64.zip
mkdir --parents .terraform/plugins/linux_amd64
mv terraform-provider-lxd_v1.2.0_x4 .terraform/plugins/linux_amd64/
