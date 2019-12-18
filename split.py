#! /usr/bin/env python

import yaml
# for keeping definition order
import yamlordereddictloader as yodl

import sys
import pprint
# for keeping definition order
from collections import OrderedDict


# cruft
class Data(object):
    def __init__(self, **kwargs):
        self.__data__ = OrderedDict(**kwargs)

    def __getitem__(self, key):
        return self.__data__[key]

    __getattr__ = __getitem__

    def __setitem__(self, key, value):
        self.__data__[key] = value

    def __setattr__(self, key,  value):
        if key == '__data__':
            super(Data, self).__setattr__(key, value)
        else:
            self.__setitem__(key, value)


def split_network_config(network_config):
    virt_nc = []
    hs_nc = []

    for interface in network_config:
        # print(interface)

        ###### virt_data
        # skip the virtual ones
        virt_iface = OrderedDict()

        # if not interface.get('type', None) in ('bond', 'vlan'):
        # if interface.get('type', None) == 'eth':
        # if 'switch' in interface:

        for key in ('name', 'type', 'slaves', 'parent', 'switch', 'use'):
            if key in interface:
                virt_iface[key] = interface[key]
        virt_nc.append(virt_iface)

        # disable because we don't allow implied interfaces anymore
        if False:
            if interface.get('type', None) == 'bond':
                for slave in interface['slaves']:
                    # check the slave itself is not another virtual/composite type
                    ifaces = [ iface for iface in network_config if iface['name'] == slave ]
                    # print(ifaces)
                    # I used to check the type here, but if it is declared (len == 1), then we'll read that declaration
                    # or ( len(ifaces) == 1 and ifaces[0]['type'] not in ('bond', 'vlan') )
                    if len(ifaces) == 0:
                        virt_nc.append(OrderedDict(name=slave))

            elif interface.get('type', None) == 'vlan':
                phys = interface['phys-dev']
                # check the slave itself is not another virtual/composite type
                ifaces = [ iface for iface in network_config if iface['name'] == phys ]
                # print(ifaces)
                # I used to check the type here, but if it is declared (len == 1), then we'll read that declaration
                # or len(ifaces) == 1 and ifaces[0]['type'] not in ('bond', 'vlan')
                if len(ifaces) == 0:
                    virt_nc.append(OrderedDict(name=phys))

        # print()

        ###### hs_data
        hs_iface = OrderedDict()
        for key in ('name', 'type', 'use',
                    'prefix', 'gateway', 'static-routes', 'dns-servers',
                    'bond-type', 'slaves',
                    'vlan-tag', 'phys-dev'):
            if key in interface:
                hs_iface[key] = interface[key]
        hs_nc.append(hs_iface)

    return virt_nc, hs_nc


def main():
    if len(sys.argv) != 4:
        print "Usage: %s [main.yaml] [cluster.yaml] [virt.yaml]" % sys.argv[0]
        print
        print "Splits a full virtualizable cluster into a cluster and a virtualization definitions."
        sys.exit(1)

    # read the input
    data = yaml.load(open(sys.argv[1]), Loader=yodl.Loader)

    # TODO: validate
    # cluster is required

    # traverse it
    virt_data = OrderedDict()
    hs_data = OrderedDict()

    ############################################################################
    # data that goes entirely to virt_data
    virt_data['infra'] = data.get('infra', OrderedDict())
    virt_data['cluster'] = OrderedDict()
    virt_data['cluster']['name'] = data['cluster']['name']
    virt_data['cluster']['disk-config'] = data['cluster'].get('disk-config',  OrderedDict())
    virt_data['cluster']['container-config'] = data['cluster']['container-config']
    virt_data['cluster']['ssh-authorized-keys'] = data['cluster'].get('ssh-authorized-keys', [])

    ############################################################################
    # data that goes entirely to hs_data
    # hs_data['network-topology'] = OrderedDict()
    hs_data['cluster'] = OrderedDict()
    # hs_data['cluster']['name'] = data['cluster']['name']
    for key in ('domain', 'admin-endpoint', 'cmc-endpoint', 'use-hsh', 'root-password', 'cmc-password'):
        hs_data['cluster'][key] = data['cluster'][key]  # all required

    ############################################################################
    # data that has to be split
    virt_nc, hs_nc = split_network_config(data['cluster'].get('network-config', []))
    virt_data['cluster']['network-config'] = virt_nc
    # hs_data['network-topology']['network-config']   = hs_nc
    hs_data['cluster']['network-config']   = hs_nc

    ############################################################################
    # regions
    # virt_regions = {}
    virt_data['cluster']['regions'] = []
    # hs_regions = {}
    hs_data['cluster']['regions'] = []
    for region in data['cluster']['regions']:
        ###### virt_data
        virt_region = OrderedDict()
        # TODO: required
        for key in ('name', ):
            if key in region:
                virt_region[key] = region[key]
        virt_data['cluster']['regions'].append(virt_region)
        # virt_regions[region['name']] = region

        ###### hs_data
        hs_region = OrderedDict()
        for key in ('name', 'default', 'ntp-servers', 's3-endpoints', 'website-endpoint'):
            if key in region:
                hs_region[key] = region[key]
        hs_data['cluster']['regions'].append(hs_region)
        # hs_regions[region['name']] = region

        virt_region['data-centers'] = []
        hs_region['data-centers'] = []
        for dc in region['data-centers']:
            ################# network config
            ###### virt_data
            virt_dc = OrderedDict()
            for key in ('name', 'container-config'):
                if key in dc:
                    virt_dc[key] = dc[key]

            ###### hs_data
            hs_dc = OrderedDict()
            for key in ('name', ):
                if key in dc:
                    hs_dc[key] = dc[key]

            virt_nc, hs_nc = split_network_config(dc.get('network-config', []))
            # TODO: remove name-only, no-config interfaces?
            virt_dc['network-config'] = virt_nc
            hs_dc['network-config']   = hs_nc

            ################# nodes
            ###### virt_data
            # just the names
            virt_dc['nodes'] = [ OrderedDict([ ('name', node['name']),
                                               ('installer-node', node.get('installer-node', False)) ])
                                 for node in dc['nodes'] ]

            ###### hs_data
            hs_dc['nodes'] = dc['nodes']

            virt_region['data-centers'].append(virt_dc)
            hs_region['data-centers'].append(hs_dc)


    ############################################################################
    # write 2 files, one for virtualization, another for HS
    yaml.dump(hs_data,   open(sys.argv[2], 'w+'), Dumper=yodl.Dumper, default_flow_style=False)
    yaml.dump(virt_data, open(sys.argv[3], 'w+'), Dumper=yodl.Dumper, default_flow_style=False)


if __name__ == '__main__':
    main()
