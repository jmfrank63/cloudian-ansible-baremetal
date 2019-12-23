# Terrible

Terraform + Ansible (and many others) mashup for launching clusters.

## Install

### This repo

    git clone https://github.com/mdone-cloudian/cloudian-ansible-baremetal.git
    yum install -y python2-virtualenv
    git checkout tla-cc-cab-merge
    ./build-venv.sh
    source bin/activate

### LXD/LXC

For more details, see [README.LXD.LXC.md].

    yum install epel-release
    yum install snapd
    snap install lxd

Initialize LXD.

    lxd init

The program will ask several questions. Read bellow for some tips, and even
further bellow for an example run:

* The node name can be any arbitrary name, jusr remember it.  The default (the node's hostname) is good enough.
* For the moment, set it up in cluster mode but not with other nodes; that has to be tested yet.
* If you're going to have several LXD hosts, use the IP/name that you can use to reach it remotely.
* Again, no cluster.
* Use any password. Just remember it.
* Use dir based storage pool, no remote storage pools.
* No MAAS server, no existing bridge or host interface, no Fan overlay network, update images yes.
* You can print the YAML and save it for reference and troubleshooting.

Example run:

    Would you like to use LXD clustering? (yes/no) [default=no]: yes
    What name should be used to identify this node in the cluster? [default=nimbus]:
    What IP address or DNS name should be used to reach this node? [default=192.168.0.110]: 127.0.0.1
    Are you joining an existing cluster? (yes/no) [default=no]: no
    Setup password authentication on the cluster? (yes/no) [default=yes]: yes
    Trust password for new clients:
    Again:
    Do you want to configure a new local storage pool? (yes/no) [default=yes]: yes
    Name of the storage backend to use (btrfs, dir, lvm, zfs) [default=zfs]: dir
    Do you want to configure a new remote storage pool? (yes/no) [default=no]: no
    Would you like to connect to a MAAS server? (yes/no) [default=no]: no
    Would you like to configure LXD to use an existing bridge or host interface? (yes/no) [default=no]: no
    Would you like to create a new Fan overlay network? (yes/no) [default=yes]: no
    Would you like stale cached images to be updated automatically? (yes/no) [default=yes]
    Would you like a YAML "lxd init" preseed to be printed? (yes/no) [default=no]: yes

Create a network:

    lxc network create lxcbr1 dns.mode=none raw.dnsmasq="$(echo -e 'dhcp-ignore-names\nlocal-ttl=4938790\n')"

We also need a base disk image. Use this:

    mdione@demo-hv1:~$ cat .aws/credentials
    [demo3-public]
    aws_access_key_id = 00821bb4e11d21ee47fc
    aws_secret_access_key = 3KfgPxgENmlAN5bc72J3kue6Zys0f1joAzO+Lsk/

    aws s3 --profile demo3-public cp s3://public/2d8190b364998ba6edfbcd08509ffce3433f8e84c864a394e9f5c305bacf52f8.tar.gz . --endpoint-url https://s3-eu-1.demo3.cloudian.eu

    lxc image import 2d8190b364998ba6edfbcd08509ffce3433f8e84c864a394e9f5c305bacf52f8.tar.gz --alias cloud-centos/7/amd64

## Usage

The sistem uses two layers: a cluster description and an infra description. Let's start with the second,
which you have to do only once per LXD/LXC host.

### Infra

This file declares all the infra already available on the host; in the future the declarations bellow
could be replaced with dynamically build switches, routers, etc.

Copy the following config, replace the text in `[brackets]` with the answers from before, and
save it as `infra/[node_name].yaml`:

```yaml
# this si the backend we're going to use; for the moment this is the only one
backend: terraform-lxd

# everything from here is backend specific
providers:
- name: [node_name]
  scheme: https
  address: [name_or_IP]
  password: [password]

disk-pools:
- name: local
  driver: dir
  source: /var/lib/snapd/hostfs/mnt/kvm/lxd/storage-pools/local

# the alias for the disk image for the node's system
# lxc image import 2d8190b364998ba6edfbcd08509ffce3433f8e84c864a394e9f5c305bacf52f8.tar.gz --alias cloud-centos/7/amd64
image: cloud-centos/7/amd64

infra:
  switches:
  - name: 'lxcbr0'  # this is the network we defined when we installed LXD
    # leave these as this, you'll see them again in the cluster def
    use: [ 'backend', 'frontend', 'management' ]
```

### Cluster

The cluster definition is more complex, as it has to declare many details, from the network interfaces
and data disks up to the S3/CMC/Admin endpoints.

Please use `projects/demo3/main.yaml` as a tmeplate. Copy only that file to a new project dir and edit
as needed.

### Build

The system uses the ssh agent a lot. If you don't have one running (chech if `SSH_AUTH_SOCK` is defined);
otherwise just run:

    ssh-agent bash

Activate the virtual env:

    source bin/activate

Now to build the cluster:

    ./build-cluster.sh [project_dir] [infra] [hs_version]

For the moment we don't support RCs (unless you rename the bin to its target versions,
like `7.2RC45` to `7.2`). Example:

    ./build-cluster.sh projects/demo3/ infra/nimbus.yaml 7.2

This builds the nodes, provision them with IPs, copies the bin and license, and unpacks the `.bin`.
We're currently not automating the installation itself, but you can run it by hand:

    lxc exec [installer-node] bash
    cd /opt/cloudian-staging/[hs_version]
    ./cloudianInstall.sh -b -c preseed.conf -s survey.csv -k cloudian-installation-key

You will probably have to add `force` to install on underpowered nodes.

If something breaks, ask @mdione, @alberto or @gbunt.
