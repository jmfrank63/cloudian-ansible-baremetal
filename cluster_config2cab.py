#! /usr/bin/env python

import sys
# from argparse import ArgParser
from pprint import pprint
from copy import deepcopy

import yaml


def recursive_update(dst, src):
    if isinstance(src, dict):
        for key, value in src.items():
            dst[key] = recursive_update(dst.get(key, {}), value)

        return dst
    else:
        return src


def convert(input):
    output = dict(interfaces={})

    # pprint(input)

    for interface, interface_config in input.items():
        if isinstance(interface_config, str):
            continue

        if interface == 'ipmi':
            # TODO
            continue

        # pprint(interface_config)

        if interface_config['type'] == 'bond':
            # this is an special case, because at least two more interfaces
            # are declared as slaves
            config = dict(
                mode='bond_master',
                bond_type=interface_config['bond_type'],
                ipv4='disabled',
                ipv6='disabled',
            )

            # handle lacp
            if config['bond_type'] == 'lacp':
                config['bond_type'] = '802.3ad'

            for slave in interface_config['slaves']:
                output['interfaces'][slave] = dict(
                    mode='bond_slave',
                    master=interface,
                    ipv4='disabled',
                    ipv6='disabled',
                )

        elif interface_config['type'] == 'vlan':
            config = deepcopy(interface_config)
            # remove uneeded keys
            del config['use']
            # type becomes mode
            del config['type']
            config['mode'] = 'vlan'

        elif interface_config['type'] == 'normal':
            config = dict(mode='normal')

        use = interface_config.get('use', None)
        if use is not None:
            ip_address = input[use]

            if ip_address == 'dhcp':
                config['ipv4'] = 'dhcp'
            else:
                config['ipv4'] = 'static'
                config['ip_address'] = ip_address

                if 'prefix' in interface_config:
                    config['prefix'] = interface_config['prefix']
                if 'netmask' in interface_config:
                    config['netmask'] = interface_config['netmask']

            # TODO
            config['ipv6'] = 'disabled'

        output['interfaces'][interface] = config

    # pprint(output)
    return output


def main():
    input = yaml.load(open(sys.argv[1]))

    # plan: I'm not aiming for purity, so we just generate a yaml inventory with
    # all the vars

    # now, how to do the inheritance?
    # we have 3 different dicts:
    # cluster leel
    # dc level
    # hosts level

    if 'data-centers' in input['network-topology']:
        datacenters = input['network-topology']['data-centers']
        cluster_network_config = input['network-topology'].get('network-config', {})
    else:
        datacenters = input['network-topology']
        cluster_network_config = input.get('network-config', {})

    # print(datacenters)
    # pprint(cluster_network_config)

    output = dict(cloudian=dict(children={}))

    for dc_name, dc_config in datacenters.items():
        dc_network_config = deepcopy(cluster_network_config)
        # this is not recursive
        # dc_network_config.update(dc_config.get('network-config', {}))
        recursive_update(dc_network_config, dc_config.get('network-config', {}))
        # pprint(dc_network_config)
        # print()

        dc = dict(hosts={})

        print(dc_config)
        if 'racks' in dc_config:
            racks = dc_config['racks']
        else:
            racks = dc_config

        print(racks)
        for rack in racks.values():
            if isinstance(rack, dict):
                hosts = rack.keys()
                hosts_network_config = rack
            else:
                hosts = rack
                hosts_network_config = input['hosts']

            for host in hosts:
                host_network_config = deepcopy(dc_network_config)
                recursive_update(host_network_config, hosts_network_config[host])

                # pprint(host_network_config)

                dc['hosts'][host] = convert(host_network_config)

        output['cloudian']['children'][dc_name] = dc

        output['all'] = { 'vars': {'run_from_iso': True } }

    open(sys.argv[2], 'w+').write(yaml.dump(output, default_flow_style=False))


if __name__ == '__main__':
    main()
