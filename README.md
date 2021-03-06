# cloudian-ansible-baremetal
Ansible Playbook to deploy Cloudian HyperStore on baremetal

> This Playbook has been written with Cloudian appliances in mind, but should theoretically work for any hardware or virtualized environment.
> For power mgmt and provisioning of the OS layer eg. *Foreman*, *Spacewalk*+*Cobbler*, *MaaS* or a plain *PXE-boot server* can be used. For all those an inventory already exists.

NOTE:
> Playbook is intended to be used for initial deployment of (typically large scale) Clusters "*behind the rack*". Meaning connect as many nodes as you can to a temporary
> switch locally (eg. per DC) to supply nodes their configuration via Ansible. The `cleanup.yml` playbook can be used at the end to destroy the temporary provision network.
> Configuration can be supplied in 1-go, *dc-by-dc* or *node-by-node*. See FAQ for more details.

## Features
 - Provisions and configures HyperStore prerequisites
 - Configures LACP network bonding
 - Configures frontend/backend VLAN interfaces
 - Initializes data disks (if not done so already)
 - Deploys HyperStore software on designated installer node
 - Deploys CloudianTools to all nodes
 - Generates survey file
 - Supports any number of Datacenters
 - Support both flat as routed DC setups (optional backend-routes will be automatically created)
 - Single Region (for now)
 - Configuration of BMC
 - Node discovery (chassis blinking) to generate Ansible inventory


## Requirements
 - Stock Cloudian appliances or some nodes running a minimal CentOS 7
 - No "final" network required (that's what Ansible will setup) but one of the 1Gb interfaces should have DHCP enabled ("eno1" by default on Cloudian appliances)
 - A small mgmt node running a DHCP server, packages:
   - `dhcp`
   - `ansible` >= 2.5
   - `python-netaddr`
 - Always first perform an `ansible-playbook` which includes the installer node. Subsequent runs can be limited to any DC or nodes

## Instructions
- Clone this repository
- Place a Cloudian Installer .bin and license in `roles/pre-installer/files`. See README.md on how to obtain those
- Customize `deployCluster.yml`
- Edit `group_vars/cloudian.yml` and set credentials, `provision_interface` and optionally `identify_interface`
- Customize `group_vars/region-1.yml`
- Customize and/or add `group_vars/DC[n].yml`
- Customize `inventory/topology`
- Optionally run `./node_discovery.py` (see FAQ)
- Finally run: `ansible-playbook deployCluster.yml (use `--limit` if only a selected number of nodes or DCs are reachable at any give time. See FAQ)
- After a batch has run successfully, you can run a cleanup: `ansible-playbook cleanup.yml` (will reboot nodes into their final configuration)

## FAQ

> How to find out which node has which DHCP lease and what addresses need to be used in `inventory/topology`?

Run `./node_discovery.py`:

```
 Select Datacenter:

 * dc1
   dc2
   dc3
```

```
 Watch chassis LEDs. Which node is blinking?

   cloudian-node1
   cloudian-node2
 * cloudian-node3
   cloudian-node4
   cloudian-node5
   cloudian-node6
```
```
 * cloudian-node1
   cloudian-node2
   cloudian-node4
   cloudian-node5
   cloudian-node6
```

after identifying all nodes within a DC, `node_discovery.py` will output an inventory list:

```
[cloudian]
cloudian-node1 ansible_host=10.254.254.122
cloudian-node2 ansible_host=10.254.254.124
cloudian-node3 ansible_host=10.254.254.121
cloudian-node4 ansible_host=10.254.254.123
cloudian-node5 ansible_host=10.254.254.125
cloudian-node6 ansible_host=10.254.254.126
```

You can use that to update your `inventory/topology` to make sure the right configuration is provisioned to the correct nodes.


> How to only run within a single Datacenter?

Limit the run to that DC. Eg. `ansible-playbook deployCluster.yml --limit 'DC1'`

> How to limit a run per-node?

Eg. `ansible-playbook deployCluster.yml --limit '<hostname>'`

> How to add Datacenters?

 - In the `inventory/topology` file just add a new Datacenter group with nodes, eg.:

```
[DC4]
cloudian-node19
cloudian-node20
cloudian-node21
```

- Add the new nodes to the `[cloudian]` groups in the `topology` inventory as well (optionally using `node_discovery.py` to identify the nodes)
- Also add the additional DC to the Region:

```
[region-1:children]
..
DC4
```

- Create and customize `group_vars/DC4.yml`

> How to switch to a setup where DC networks are routed?

- In `deployCluster.yml` set `net_cfg_routes: true`
- In `group_vars/DC[n].yml` override any parameters which will likely be different between DCs (VLANs, gateways etc.)
- Routes between DC backend networks will now be automatically created during Ansible run

> Can this playbook be used with other dynamic inventories?

Yes. Although the static `inventory/topology` is used to define which nodes reside in which Datacenters, this information could be supplied by other inventories as well, eg. when
using the [Foreman Ansible Inventory](https://github.com/theforeman/foreman_ansible_inventory), the right groups should be created in Foreman and attached to the provisioned nodes.
Alternatively multiple inventories can also be combined so the static `topology` inventory is used in combination with a simple dynamic inventory only supplying group `cloudian`.

> How to use the playbook to add additional nodes to an existing Cluster?

The playbook has been created specifically to cover initial deployments. Depending on how (and if) it's setup to manage and control an existing cluster going forward, it should be very easy to
add a new node: Just add it to the right groups with the temporary address taken from a provisioning subnet the node booted from. Do keep in mind that when managing a production cluster, it might
be advisable to disable some potentially destructive tasks, like `common/cloudian_disks.yml` just to be sure.
