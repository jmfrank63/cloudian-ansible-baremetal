#! /bin/bash

if [ -z "$VIRTUAL_ENV" ]; then
    echo "Virtual Env not active. Please run the following: source bin/activate"
    exit 1
fi

set -eu

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 [project]"
    echo
    echo "Builds an ISO to be mounted on each node via IPMI/BMC."
    exit 1
fi

project="$1"
shift

# there's no need for infra here, and we're building files that don't need it
make PROJECT_DIR="$project" INFRA="" "${project}/inventory.yaml"

ansible-playbook --syntax-check --inventory-file "${project}/inventory.yaml" deployCluster.yml

# ./check_config.py

# make relative
/usr/bin/python2 -m virtualenv --relocatable .

# try harder
sed -i -e 's/VIRTUAL_ENV=".*"/VIRTUAL_ENV="$(pwd)"/' bin/activate

mkdir -pv tmp mnt

# trim.sh is copied because it's run in the staging dir; it will removed later
rsync --archive --update --delete --exclude '*terraform' \
    bin lib share group_vars inventory roles \
    deployCluster.yml run-from-iso.sh trim.sh \
    tmp/

# run.sh is not executable here (to avoid mistakes that can destroy your dev machine)
chmod 755 tmp/run-from-iso.sh

# fix symlinks for CentOS
for dir in encodings lib-dynload; do
    src="/usr/lib64/python2.7/$dir"
    dst="tmp/lib/python2.7/$dir"

    rm -fv "$dst"
    ln -sv "$src" "$dst"
done

(
    cd tmp

    ./trim.sh --all
    rm trim.sh

    # generate an ssh key pair
    ssh_key="roles/common/files/cloudian-installation-key"
    if [ ! -f "$ssh_key.pub" ]; then
        ssh-keygen -v -b 2048 -t rsa -f $ssh_key -q -N '' -C 'cloudian_master_key'
        # move the priv key to the pre-installer role
        mv -v $ssh_key     roles/pre-installer/files/
        cp -v $ssh_key.pub roles/pre-installer/files/
    fi

    genisoimage -volid "MagicConfiblugator" \
        -appid Cloudian -publisher Cloudian -preparer "Marcos Dione" -sysid LINUX \
        -volset-size 1 -volset-seqno 1 -rational-rock -joliet -joliet-long \
        -no-cache-inodes -full-iso9660-filenames -disable-deep-relocation -iso-level 3 \
        -input-charset utf-8 \
        -o "../${project}/abi.iso" .

    echo
    echo "ISO written to ${project}/abi.iso"
    echo
)
