# LXD/LXC

LXC is a container system built by Canonical. Initially it only worked on the local machine, but then
Canonical developed LXD, which provides both an API and a remote control. Confusingly, most control of
both systems are handled by the `lxc` binary.

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

    lxc network create lxcbr0 dns.mode=none raw.dnsmasq="$(echo -e 'dhcp-ignore-names\nlocal-ttl=4938790\n')"

This will create a bridge `lxcbr0` with an instance of `dnsmasq` that serves DNS and DHCP. The config
options are so the DNS system does not reflect the node's names associated to the DHCP IP. In the future,
networks (that we use as 'switches') will be provided per cluster, so several clusters can have similar
IPs.


## Terraform

Install it by running:

    ./get-terraform.sh


## Python deps

We will install several deps (including Ansible) in a Python VirtualEnd:

    ./build-venv.sh


## Configure

The system tries to separate the definition of your cluster from the infrastructure that's going to
support it.

### Project

The Terrible mode can handle different projects at the same time. Projects are directories under the
`projects` directory. Usually the on;y file you need to modify in this directory is called `main.yaml`.
This file declares your cluster and its relationship with the infra; we will talk about this in a
moment. You can check the `demo3` project to have an idea of how to declare things, maybe use it as a
template.

### Infra

You can declare existing infrastructure in a file under `infra`. Currently we only support
`terraform-lxd` as backend. In that case, you have to configure at least one provider, one disk pool
and the image to use as base for the HyperStore nodes. Please check `infra/ams.yaml` and
`infra/nimbus.yaml` as examples. Notice that in the case of `nimbusyaml`, it makes reference to the
bridge built up there.


## Build

Once you have your infra and project, you can proceed to build the cluster:

    ./build-cluster.sh [project_dir] [infra] [hs_version]

For example:

    ./build-cluster.sh projects/demo3/ ams 7.2


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
