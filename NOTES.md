# Intro

This set of tool has the final goal of configuring a HS cluster, using three different methods:

* Connecting all nodes in a DC to a switch and your laptop.
* Creating an ISO that can be mounted via IPMI/BMC an run locally on the node
* Configuring virtual nodes via ssh.

For this we use Ansible, and some other deps. `sshpass`.

# Usage

* Copy the `.bin` and license files (as `cloudian_license.lic` in `roles/pre-installer/files`.
  If needed, also provide the `survey.csv` file.

## Inventory

The inventory can be written in different ways, depending on where and how you want to deploy.

The most basic use implies you write/modify the files in `group_vars/` and `inventory/topology`.
This of course is not automatic.



# Technical details

There are a few Ansible Playbooks. These can also be paired with inventory files that define the final config
of the nodes.

* deployCluster.yml

Defines two groups of nodes, `installer-node` and `cloudian`. The first is one fo the `cloudian` nodes that
also receives the installer, survey file and license.

## installer_node

This group must include only the node declared as the installer node.

Task                                                                                    | Switch | ISO | Orchestrator
-----------------------------------------------------------------------------------------------------------------
Creates staging dir                                                                     | ✔      | ✔   | ✔
Copies the bin and license file and extracs it.                                         | ✔      |     | ✔
Reads `system_setup.sh` from the installer node, as variable and fact                   | ✔      |     | ✔
Generates `/etc/cloudian/PreInstallConfig.txt`.                                         | ✔      | ✔   | ✔
Generates a ssh key pair                                                                | ✔      |     | ✔
Copies the ssh key pair into the installer node from the ISO                            |        | ✔   |
Writes the `survey.csv` file                                                            | ✔      | ✔   | ✔

As you can see, the ISO mode does not copy the `.bin` or license file. That's because the ISO has a 50MiB limit.
You **MUST** copy them to the installer node and extract by hand.

## cloudian

This group must include all nodes. It defines two roles: `common` and `bmc`

### common

Task                                                                                    | Switch | ISO | Orchestrator
-----------------------------------------------------------------------------------------------------------------
`TERM` variable.                                                                        | ✔      | ✔   | ✔
Hostname                                                                                | ✔      | ✔   | ✔
Entry in `/etc/hosts`                                                                   | ✔      | ✔   | ✔
Disables IPv6                                                                           | ✔      | ✔   | ✔
Installs packages in `packages/centos/7`                                                | ✔      | ✔   | ✔
Disables Selinux                                                                        | ✔      | ✔   | ✔
Setup networking, interfaces and routes, including complex setups.                      | ✔      | ✔   | ✔
Enable password authentication for `ssh`.                                               | ✔      | ✔   | ✔
Aloow `root` to login.                                                                  | ✔      | ✔   | ✔
Timezone                                                                                | ✔      | ✔   | ✔
Setup disks                                                                             | ✔      | ✔   | ✔
Add the ssh pub key from the installer node to root's `authorized_keys` file            | ✔      | ✔   | ✔ [1]
Copies `system_setup.sh` from the installer node                                        | ✔      |     | ✔
Copies `system_setup.sh` from the ISO                                                   |        | ✔   |

[1] The way this is done in ISO mode is different, but the result is the same.

### bmc

Task                                                                                    | Switch | ISO | Orchestrator
-----------------------------------------------------------------------------------------------------------------
Configures the ipmi interface.                                                          | If BMC/IPMI iface detected
