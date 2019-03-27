# Run from ISO

An alternative to accessing the DC and physically connecting to the back of the
nodes is to generate an ISO-9960 image with Ansible, these playbooks and a few
more things, mount it through the virtual device support of the IPMI/BMC system,
and run locally.

## Requirements

* `genisoimage`
* `python-virtualenv`

## Executive summary (a.k.a. TL:DR)

* Clone this repo.
* Run `./build-venv.sh` to crate a Python virtaulenv with all the dependencies.
* `source bin/activate`

* Edit `inventory/cluster.yaml` to suit your needs.
* Edit `roles/pre-install/files/survey.csv` according to the previous file. (TODO: this file should be generated)
* Run `./build-iso.sh`
  * This creates a file called `abi.iso`

* Mount `abi.iso` on each node through the Virtual Device support of your node's
  IPMI/BMC implementation.
* Using the remote console, run:
  * `mount /dev/sr0 /mnt`
  * `cd /mnt`
  * `./run-from-iso.sh <node_hostname>`

## Network architecture support

This new version is more flexible when handling the network architecture. This
flexibility comes at a price: You have to declare exactly how the network setup
looks like, instead of the original assumption about interfaces, bonding and
vlans.

Network definition is done in the `interfaces` mapping on each node. There you
shoud declare a mapping for each interface:

          interfaces:
            <iface>:
              mode: disabled|normal|bond_master|bond_slave|vlan
              # options for bond_master
              bond_type: 0-6|balance-rr|active-backup|balance-xor|broadcast|802.3ad|balance-tlb|balance-alb
              # options for bond_slave
              master: ...
              # options for vlan
              vlan_tag: ...
              physdev: ...

              ipv4: disabled|static|dhcp
              # options for static
              ip_address: ...
              # the following two are alternatives to declare the same thing
              prefix: ...
              netmask: ...
              # this is optional
              gateway: ...

              # this can be used in sattic and dhcp modes; optional
              dns-servers: ...

              # in general, disabled
              ipv6: disabled|dhcp|slaac

            [...]

You have to declare all the interfaces in the node, so please declare those not
used as `disabled`. In general, `ipv4` has to be `disabled` for `bond_slave`
and `physdev` of `vlan` interfaces.

Also, you have to declare which IP is going to be used on the frontend and
optionally the IPMI/BMC config:

          net_frontend_addr: ...
          bmc_addr: ...
          bmc_gateway: ...
          bmc_prefix: ...

## Cluster compiler

In theory, you could do it all editing those files in the [TL;DR section](), but
it's kinda cumbersome and sometimes repetitive. Common settings could be moved
up to the DC or cluster declarations, but I decided to have them on each node to
make it easier to review each node's config.

Also, because this is run on each node individually, we can't rely on Ansible to
generate the `survey.csv` file on the fly, so we need to write it beforehand.
Consequently, both files have duplicate data, and that's exactly what we want to
avoid.

For that, you can generate both files from a more abstract cluster definition
file. See the files under the `cluster/` directory. My suggestion is to copy one
of those files into a client file, modify that one, and run the complier with it.

Running the compiler is as simple as:

    ./cluster_config2cab.py cluster/foo.yaml inventory/cluster.yaml

This also generates the `survey.csv` file.

Once that's done, you can continue with the instructions at the beginning of this
file. You can also edit `inventory/cluster.yaml` to further customize if needed.
Please report any non supported options.
