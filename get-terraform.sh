#! /bin/bash

set -eu

wget https://releases.hashicorp.com/terraform/0.12.2/terraform_0.12.2_linux_amd64.zip
unzip terraform_0.12.2_linux_amd64.zip
mv terraform bin/

wget https://github.com/sl1pm4t/terraform-provider-lxd/releases/download/v1.2.0/terraform-provider-lxd_v1.2.0_linux_amd64.zip
unzip terraform-provider-lxd_v1.2.0_linux_amd64.zip
mkdir --parents .terraform/plugins/linux_amd64
mv terraform-provider-lxd_v1.2.0_x4 .terraform/plugins/linux_amd64/
