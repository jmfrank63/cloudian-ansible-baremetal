#! /bin/bash

set -e

# ansible is quote big, while some computers immpose a 50MiB size on virtual CD immages
# this script removes unused ansible code to fit in that limit

while [ $# -gt 0 ]; do
    case "$1" in
      -a|--all)
        # get rid of some python packages
        for module in pip setuptools pkg_resources wheel; do
            rm -rf "lib/python2.7/site-packages/$module"
        done

        shift
        ;;
    esac
done

# cleanup
find lib -name '*.py' -o -name '*.dist-info' | egrep -v 'module|plugins' | xargs rm -rf

for module in paramiko pycparser; do
    rm -rf "lib/python2.7/site-packages/$module"
done

ansible_prefix="lib/python2.7/site-packages/ansible"

# trim down modules
for module in cloud clustering database network notification remote_management source_control web_infrastructure windows; do
    rm -rf $ansible_prefix/modules/$module
done

# picking some by hand
find $ansible_prefix/module_utils | \
    egrep -v 'module_utils$|__init__|facts|parsing|six|_text|api|basic|connection|crypto|ismount|json|known_hosts|network|pycompat|redhat|service|splitter|urls' | \
    xargs -r rm -rf
find $ansible_prefix/module_utils/network -type d | egrep -v 'network$|common' | xargs -r rm -rf

find $ansible_prefix/modules/packaging -type f | \
    egrep -v '__init__|package|redhat|rhn|rhsm|rpm|yum' | xargs -r rm
find $ansible_prefix/modules/system    -type f | \
    egrep -v '__init__|authorized_key|cron|filesystem|hostname|known_hosts|lvg|lvol|modprobe|mount|parted|selinux|service|setup|sysctl|systemd|timezone' | \
    xargs -r rm
