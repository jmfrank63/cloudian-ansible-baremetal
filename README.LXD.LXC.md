# LXD/LXC

LXC is a container system built by Canonical. Initially it only worked on the local machine, but then
Canonical developed LXD, which both an AIP and remote control. Confusingly, most control of both systems
are handled by the `lxc` binary.

## Install

Both versions should install LXD/LXC 3.x

### *buntu

    apt install snapd

### CentOS

    yum install epel-release
    yum install snapd

### Both

    snap install lxd

Initially there will be no network, so we just create one:

    lxc network create lxcbr0 dns.mode=none raw.dnsmasq='dhcp-ignore-names'

This will create a bridge `lxcbr0` with an instance of `dnsmasq` that serves DNS and DHCP. The config
options are so the DNS system does not reflect the node's names associated to the DHCP IP. In the future,
networks (that we use as 'switches') will be provided per cluster, so several clusters can have similar
IPs.

## Specificities

Besides the interfaces you define, this system will add an interface called `provision`. This interface
is configured so it obtains a random IP from the DHCP server. Ansible provisions the nodes through this
interface, and you can use it as a kind of IPMI interface. You can't reconfigure it, tho.


## Directories/Files:

LXC has several parts:

* containers + instances
* disk images
* data volumes
* networks

* Logs: `/var/snap/lxd/common/lxd/logs/[node]`
/var/snap/lxd/common/lxd/storage-pools/local/containers/[node]

* Latest configuration in YAML format: `/var/snap/lxd/common/lxd/containers/[node]/backup.yaml`

/var/snap/lxd/common/lxd/devices/[node]/disk.cloudian001.cloudian001
/var/snap/lxd/common/lxd/storage-pools/local/custom/[node]-cloudian001

/var/snap/lxd/common/lxd/images
