#! /bin/bash

set -eu

ansible-playbook --syntax-check --inventory-file inventory/cluster.yaml deployCluster.yml

# ./check_config.py

# make relative
/usr/bin/python2 -m virtualenv --relocatable .

# try harder
sed -i -e 's/VIRTUAL_ENV=".*"/VIRTUAL_ENV="$(pwd)"/' bin/activate

mkdir -pv tmp mnt

# trim.sh is copied because it's run in the staging dir; it will removed later
rsync --archive --update --progress --delete \
    bin lib share group_vars inventory roles deployCluster.yml run.sh trim.sh \
    tmp/

# run.sh is not executable here (to avoid mistakes that can destroy your dev machine)
chmod 755 tmp/run.sh

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

    genisoimage -volid "MagicConfiblugator" \
        -appid Cloudian -publisher Cloudian -preparer "Marcos Dione" -sysid LINUX \
        -volset-size 1 -volset-seqno 1 -rational-rock -joliet -joliet-long \
        -no-cache-inodes -full-iso9660-filenames -disable-deep-relocation -iso-level 3 \
        -input-charset utf-8 \
        -o ../abi.iso .
)