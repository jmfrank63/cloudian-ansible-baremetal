#! /usr/bin/env python2

import yaml
# for keeping definitions' order
import yamlordereddictloader as yodl

import sys
# for keeping definitions' order
from collections import OrderedDict
from copy import deepcopy as copy
from os.path import dirname, join as path_join


def update(data, new_data):
    # data and new_data are not a dictionaries anymore, so we take each node's name in new_data, find it in data
    # and update that dictionary
    for node in new_data:
        name = node['name']
        try:
            obj = [ obj for obj in data if obj['name'] == name ][0]
        except IndexError:
            data.append(node)
        else:
            obj.update(node)


def terraform_lxd(config, infra, nodes, backend_files):
    # write main.tf
    # TODO: use a template system
    tf = open(backend_files[0], 'w+')
    tf.write('''provider "lxd" {
    generate_client_certificates = true
    accept_remote_certificate    = true

''')

    for provider in infra['providers']:
        # pprint(provider)
        tf.write('''    lxd_remote {
        name     = "%(name)s"
        scheme   = "%(scheme)s"
        address  = "%(address)s"
        password = "%(password)s"
    }

''' % provider)

    tf.write('''}

''')

    # write disk pools; we don't need to declare infra pools
    use_default_pool = True
    default_pool = None
    for pool in infra.get('disk-pools', []):
        if use_default_pool and default_pool is None:
            default_pool = pool
        else:
            use_default_pool = False
            default_pool = None

        for provider in infra['providers']:
            pool['remote'] = provider['name']

    for pool in config.get('disk-pools', []):
        for provider in infra['providers']:
            tf.write('''resource "lxd_storage_pool" "%(remote)s-%(name)s" {
    name   = "%(remote)s-%(name)s"
    remote = "%(remote)s"
    driver = "%(driver)s"
    config = {
        source = "%(source)s"
    }
}

''' % pool)

    installer_node = None

    # write volumes, one per disk per node
    for node in nodes:
        # seize the opportunity and find the installer_node
        if node.get('installer-node', False):
            if installer_node is None:
                installer_node = node
            else:
                raise ValidationError( 'More than one node are declared as the installer node, %s and %s' %
                                       (node['name'], installer_node['node']) )

        for disk in node['disk-config']:
            if 'mount-point' in disk and 'cloudian' in disk['mount-point']:
                if default_pool is not None:
                    disk['pool'] = default_pool['name']

                if 'count' in disk:
                    for number in range(1, disk['count'] + 1):

                        new_disk = copy(disk)
                        new_disk['mount-point'] = (disk['mount-point'] + '%d') % number
                        new_disk['disk-name'] = disk_name(new_disk)

                        write_volume(tf, node, new_disk)
                else:
                    disk['disk-name'] = disk_name(disk)

                    write_volume(tf, node, disk)

    for node in nodes:
        node['image'] = infra['image']
        tf.write('''resource "lxd_container" "%(name)s" {
    remote = "%(host)s"
    name = "%(name)s"
    image = "%(image)s"
    ephemeral = false

    limits = {
        cpu = %(cpus)d
        memory = "%(memory)dGB"
    }

''' % node)

        # write provision interface
        if infra.get('infra', None) is None or infra['infra'].get('switches', None) is None:
            # default lxd bridge
            switch = 'lxcbr0'
        else:
            # find the frontend switch
            switch = [ switch['name'] for switch in infra['infra']['switches'] if 'frontend' in switch['use'] ][0]

        tf.write('''    device {
        name = "provision"
        type = "nic"
        properties = {
            name    = "provision"
            nictype = "bridged"
            parent  = "%(switch)s"
        }
    }

''' % dict(switch=switch))

        for interface in node['network-config']:
            # pprint(interface)
            tf.write('''    device {
        name = "%(name)s"
        type = "nic"
''' % interface)
            if 'switch' in interface:
                tf.write('''        properties = {
            name    = "%(name)s"
            nictype = "bridged"
            parent  = "%(switch)s"
        }
''' % interface)

            tf.write('''    }

''')

        for disk in node['disk-config']:
            if 'mount-point' in disk and 'cloudian' in disk['mount-point']:
                # a cloudian data disk, maybe several (see count)

                if 'count' in disk:
                    for number in range(1, disk['count'] + 1):
                        new_disk = copy(disk)
                        new_disk['mount-point'] = (disk['mount-point'] + '%d') % number
                        new_disk['disk-name'] = disk_name(new_disk)

                        write_disk(tf, node, new_disk)
                else:
                    write_disk(tf, node, disk)

        # force dependency on disks, because for some reason TF is not picking that up
        tf.write('''    depends_on = [
''')
        for disk in node['disk-config']:
            if 'mount-point' in disk and 'cloudian' in disk['mount-point']:
                # a cloudian data disk, maybe several (see count)

                for number in range(1, disk['count'] + 1):
                    new_disk = copy(disk)
                    new_disk.update(node)
                    new_disk['mount-point'] = (disk['mount-point'] + '%d') % number
                    new_disk['disk-name'] = disk_name(new_disk)

                    tf.write('''        lxd_volume.%(name)s-%(disk-name)s,
''' % new_disk)
        tf.write('''    ]

''')


        # node's coda
        pub_key_file = path_join(dirname(backend_files[0]), 'cloudian-installation-key.pub')
        install_key = open(pub_key_file).read()
        data = {
            'installer-node': str(node['installer-node']).lower(),
            'install-key': install_key,
        }

        # user.usr-data is config for cloud-config

        # NOTE: the #cloud-config line is IMPORTANT.

        # avoid: pam_loginuid(sshd:session): Cannot open /proc/self/loginuid: Permission denied
        # \t's must be escaped as \\t

        # the hardcoded key is the one used by terraform-lxd-ansible
        tf.write('''    config {
        boot.autostart = true

        user.cloudian.installer = %(installer-node)s
        user.user-data = <<EOF
#cloud-config

runcmd:
  - sed -i 's/session.*required.*pam_loginuid.so/#session\\trequired\\tpam_loginuid.so/' /etc/pam.d/*
  - sed -i 's/session.*required.*pam_limits.so/#session\\trequired\\tpam_limits.so/' /etc/pam.d/*

locale: en_US.UTF-8
timezone: Europe/Amsterdam

users:
  - name: root
    ssh_authorized_keys:
    - %(install-key)s
''' % data)

        # print(config['cluster']['ssh-authorized-keys'])
        auth_keys = config['cluster'].get('ssh-authorized-keys', [])
        if auth_keys is None:
            # the key was persent but it had no data
            auth_keys = []

        for key in auth_keys:
            tf.write('''    - %(key)s
''' % dict(key=key))

        tf.write('''
EOF

''')

        tf.write('''        user.network-config = <<EOF
version: 1
config:
- name: provision
  type: physical
  subnets:
  - type: dhcp

''')

        for interface in node['network-config']:
            tf.write('''- name: %(name)s
  type: physical

''' % interface)

        tf.write('''EOF
    }
''')

        tf.write('''}

''')

    # coda
    # terraform will calculate and extrapolate the ${values} in this text

    # A null-resource to force Ansible to run as last
    # by doing a remote exec on last node in line
    # then issue a local-exec running Ansible
    # See: ansible/inventory/terraform.py on how
    # nodes are discovered based on terraform.tfstate

    # TODO:
    # How is that list sorted? Ideally we test the last node that came up
    # TODO: We _need_ all nodes to be ready before tfstate is parsed.
    # host     = "${element(lxd_container.node.*.ip_address, local.numnodes -1)}"
    # For now static node1 as that will run role pre-installer first:

    tf.write('''
locals {
    numnodes = "length(lxd_container.node.*.id)"
}

resource "null_resource" "ansible" {
    depends_on = [
''')

    for node in nodes:
        tf.write('''        lxd_container.%(name)s,
''' % node)

    tf.write('''    ]

''')
    tf.write('''    provisioner "remote-exec" {
        inline = ["true"]  // this is atually the command to execute. a trick, evidently.

        connection {
            type        = "ssh"
            user        = "root"
            private_key = "file('cloudian-installation-key')"
            host        = "lxd_container.%(name)s.ip_address"
        }
    }
}
''' % installer_node)



def write_volume(tf, node, disk):
    # keep this order so the node's name overwrite's the disk's name
    merge = copy(disk)
    merge.update(node)

    tf.write('''resource "lxd_volume" "%(name)s-%(disk-name)s" {
    name   = "%(name)s-%(disk-name)s"
    remote = "%(host)s"
    pool   = "%(pool)s"
}

''' % merge)

def disk_name(disk):
    # remove leading / -
    return disk['mount-point'].replace('/', '-')[1:]


def write_disk(tf, node, disk):
    # keep this order so the node's name overwrite's the disk's name
    merge = copy(disk)
    merge.update(node)

    # size   = %(size)d  # Only the root disk may have a size quota.
    tf.write('''    device {
        name = "%(disk-name)s"
        type = "disk"
        properties = {
            path   = "%(mount-point)s"
            source = "%(name)s-%(disk-name)s"
            pool   = "%(pool)s"
        }
    }

''' % merge)


class ValidationError(ValueError):
    pass


def find_by_attr(key, value, list):
    ''' Find an element in list whose key key has value value.'''

    return [ item for item in list if item[key] == value ]


def find_by_name(name, list):
    '''Find an element in list whose name is name.'''

    found = find_by_attr('name', name, list)

    if len(found) == 0:
        return None
    elif len(found) == 1:
        return found[0]
    else:
        raise ValidationError("%s appears more that once in %r" % (name, list) )


def find_switch(switch, config, infra):
    '''Tries to find the switch in the config first, otherwise in the infra.'''

    if 'switches' in config['infra']:
        found = find_by_name(switch, config['infra']['switches'])
        if found is not None:
            return found

    if 'infra' not in infra or 'switches' not in infra['infra']:
        return 'lxcbr0'

    return find_by_name(switch, infra['infra']['switches'])


def check_infra(config, infra, nodes):
    # container-config.host is defined as a provider
    for node in nodes:
        for interface in node['network-config']:
            # pprint(interface)

            # find the switch that has this interface's use
            use = interface['use']

            switch = None
            switches = ( config.get('infra', {}).get('switches', []) +
                         infra.get('infra', {}).get('switches', []) )

            for sw in switches:
                if use in sw['use']:
                    switch = sw
                    break

            if switch is None:
                raise ValidationError('Cloud not find switch with use %r.' % use)

            interface['switch'] = switch['name']


def check_network(config, infra, nodes):
    # interface's switch is defined as a switch
    # gateways/static-routes as routers' addresses
    # bonds' slaves are defined
    # bonds' slaves connect all to the same switch
    # vlans' parents are defined
    # vlans' parents connect all to the same switch
    return True


def main():
    if len(sys.argv) != 4:
        print "Usage: %s [virt.yaml] [infra.yaml] [backend-files ...]" % sys.argv[0]
        print
        print "Generates backend configuration files/scripts based on the desired cluster and the available infra."
        sys.exit(1)

    # read the input
    config = yaml.load(open(sys.argv[1]), Loader=yodl.Loader)
    # pprint(config)
    infra = yaml.load(open(sys.argv[2]), Loader=yodl.Loader)

    nodes = []

    # trickle down data
    # cluster's, regions' and dcs' network-config and disk-config data trickles down to node level
    # I aready wrote this code, maybe I should factor it out

    cluster_nc = copy(config['cluster'].get('network-config', []))
    cluster_cc = copy(config['cluster'].get('container-config', []))
    cluster_dc = copy(config['cluster'].get('disk-config', []))

    for region in config['cluster']['regions']:
        region_nc = copy(cluster_nc)
        # pprint(region_nc)
        update(region_nc, region.get('network-config', []))
        # pprint(region_nc)

        # container-config is a dict
        region_cc = copy(cluster_cc)
        region_cc.update(region.get('container-config', {}))

        region_dc = copy(cluster_dc)
        update(region_dc, region.get('disk-config', []))

        for dc in region['data-centers']:
            dc_nc = copy(region_nc)
            # pprint(dc_nc)
            update(dc_nc, dc.get('network-config', []))
            # pprint([id(dc_nc), dc_nc])

            dc_cc = copy(region_cc)
            dc_cc.update(dc.get('container-config', []))

            dc_dc = copy(region_dc)
            update(dc_dc, dc.get('disk-config', []))

            for node in dc.get('nodes', []):
                node_nc = copy(dc_nc)
                update(node_nc, node.get('network-config', []))
                # pprint(node_nc)

                node_cc = copy(dc_cc)
                node_cc.update(node.get('container-config',  []))

                node_dc = copy(dc_dc)
                update(node_dc, node.get('disk-config',  []))

                # values to simplify extrapolation later
                node['cluster_name'] = config['cluster']['name']

                node['network-config'] = node_nc
                # node['container-config'] = node_cc
                node.update(node_cc)
                # pprint(node)
                node['disk-config']    = node_dc

                # trickle down interface use
                # it has to be done in vlan, bond, eth order
                for interface in find_by_attr('type', 'vlan', node['network-config']):
                    copy_interface_use(interface, node['network-config'])

                for interface in find_by_attr('type', 'bond', node['network-config']):
                    copy_interface_use(interface, node['network-config'])

                nodes.append(node)
                # pprint(nodes)
                # print

    # yaml.dump(nodes, open('debug.yaml', 'w+'), Dumper=yodl.Dumper, default_flow_style=False)

    check_infra(config, infra, nodes)
    check_network(config, infra, nodes)

    # terraform-lxd becomes terraform_lxd
    f = globals()[infra['backend'].replace('-', '_')]
    backend_files = sys.argv[3:]
    f(config, infra, nodes, backend_files)


def copy_interface_use(interface, interfaces):
    '''Copy use values from one virtual interface towards the physical ones.'''
    if 'use' in interface:
        if   interface['type'] == 'vlan':
            # trickle to parent
            parent = find_by_name(interface['parent'], interfaces)
            append_uses(parent, interface['use'])

        elif interface['type'] == 'bond':
            # trickle to slaves
            for slave_name in interface['slaves']:
                slave = find_by_name(slave_name, interfaces)
                if slave is None:
                    # this should be in check_network() anyways
                    raise ValidationError( "%s: %s: Slave %s does not exist." %
                                            (node['name'], interface['name'], slave_name) )

                append_uses(slave, interface['use'])


def append_uses(interface, uses):
    '''Modify the interface to include more uses. Uses are types of traffic that go through the interface.
       Typical values are frontend and backend.'''

    if isinstance(uses, str):
        # convert to list
        uses = [ uses ]

    try:
        interface['use'].extend(uses)
    except AttributeError:
        # it's a string, convert to list
        interface['use'] = [ interface['use'] ].extend(uses)
    except KeyError:
        # not present, just copy over
        interface['use'] = uses


def test():
    d1 = dict(foo='bar', quux='moo')
    d2 = dict(foo=None)
    d3 = dict(bar='foo')
    assert find_by_attr('foo', 'bar', []) == []
    assert find_by_attr('foo', 'bar', [ {} ]) == []
    assert find_by_attr('foo', 'bar', [ d2 ]) == []
    assert find_by_attr('foo', 'bar', [ d2, d1, d3, d1 ]) == [ d1, d1 ]


if __name__ == '__main__':
    try:
        main()
    except ValidationError as e:
        print("Error: %s" % e.args[0])
        sys.exit(1)
