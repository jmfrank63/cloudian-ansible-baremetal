# cloudian-ansible-baremetal
Ansible Playbook to deploy Cloudian HyperStore on baremetal


## Instructions
- Clone this repository
- Edit `ansible.cfg` and set `inventory` to whatever inventory you use, eg. the [Foreman Ansible Inventory](https://github.com/theforeman/foreman_ansible_inventory)
- Expects 2 groups: *cloudian* and *installer-node*, where all nodes should be part of group *cloudian* and only 1 should be in group *installer-node*
- Place a Cloudian Installer and license in `roles/pre-installer/files`. See README.md on how to obtain those
- Edit `group_vars/cloudian` and set credentials
- Finally run: `ansible-playbook deployCluster.yml`

## Requirements:
- Some nodes running CentOS 6/7 or the latest HyperStore ISO
- Ansible v2.4

NOTES:
> Still work in progress, support for multiple Datacenters should be added as well as being able to run node-by-node (and separately in each DC).
> Obviously this will work on a virtual environment as well, but is targeted for Cloudian appliances or comparable hardware.
> For power mgmt and provisioning of the OS layer Foreman, Spacewalk+Cobbler or MaaS can be used. For all those an inventory already exists.
