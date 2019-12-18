#! /usr/bin/env python2

import sys
# from argparse import ArgParser
from pprint import pprint
from copy import deepcopy
import csv

import yaml


def recursive_update(dst, src):
    if isinstance(src, dict):
        for key, value in src.items():
            dst[key] = recursive_update(dst.get(key, {}), value)

        return dst
    else:
        return src


def update(data, new_data):
    # we take each node's name in new_data, find it in data, and update that dictionary
    for node in new_data:
        # pprint(node)
        name = node['name']
        try:
            obj = [ obj for obj in data if obj['name'] == name ][0]
        except IndexError:
            data.append(node)
        else:
            obj.update(node)


def convert(input, node):  # (List[Dict], Dict)
    output = dict(interfaces={})

    # pprint(input)

    for interface_config in input:  # Dict
        name = interface_config['name']  # str

        # TODO: fix this, becasue the types all changed now
        # skip declarations like installer or name
        if isinstance(interface_config, str) or isinstance(interface_config, bool):
            continue

        use = interface_config.get('use', None)  # str

        # pprint(interface_config)
        # print(name)

        if name == 'ipmi':
            # allow non declaration for virtual clusters
            if 'management' in node:
                # this is handled specially because the interface is declared as ipmi
                # and IP info comes from the management info and goes to specific variables
                # use: foo
                # foo        -> bmc_addr
                # prefix     -> bmc_prefix
                # gateway    -> bmc_gateway

                output['bmc_addr']    = node[use]
                output['bmc_prefix']  = interface_config['prefix']
                output['bmc_gateway'] = interface_config['gateway']

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
                    master=name,
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

        elif interface_config['type'] in ('normal', 'eth'):
            config = dict(mode='normal')

        if use is not None:
            ip_address = node[use]

            if ip_address == 'dhcp':
                config['ipv4'] = 'dhcp'
            else:
                config['ipv4'] = 'static'
                config['ip_address'] = ip_address

                if 'prefix' in interface_config:
                    config['prefix'] = interface_config['prefix']
                if 'netmask' in interface_config:
                    config['netmask'] = interface_config['netmask']
                if 'gateway' in interface_config:
                    config['gateway'] = interface_config['gateway']

            # TODO
            config['ipv6'] = 'disabled'

            if use in ('frontend', 'single') or interface_config.get('main_frontend', False):
                # TODO: check ip_address is defined
                output['net_frontend_addr'] = ip_address
                # this is helpful for ansible to find the hsts if DNS is not setup
                output['ansible_host'] = ip_address

                if 'main_frontend' in interface_config:
                    del config['main_frontend']
            elif use == 'backend':
                output['backend_iface'] = name

        output['interfaces'][name] = config

    # pprint(output)
    return output


def find_by_attr(key, value, list):
    ''' Find an element in list whose key key has value value.'''

    return [ item for item in list if item[key] == value ]


def main():
    if len(sys.argv) != 3:
        print "Usage: %s [cluster.yaml] [inventory.yaml]" % sys.argv[0]
        print
        print "Converts a cluster definition to an Ansible inventory."
        sys.exit(1)

    input = yaml.load(open(sys.argv[1]))

    # plan: I'm not aiming for purity, so we just generate a yaml inventory with
    # all the vars

    # now, how to do the inheritance?
    # we have 4 different dicts:
    # cluster level
    # region level
    # dc level
    # node level

    cluster_network_config = input['cluster'].get('network-config', [])
    # pprint(cluster_network_config)
    # print

    output = dict(cloudian=dict(children={}))

    # CIC.txt
    # TODO: support project directories
    # TODO: template
    cic = open('roles/pre-installer/files/CloudianInstallConfiguration.txt', 'w+')
    cic.write('''INSTALL_APPEND_TO_ETC_HOSTS=yes
INSTALL_CONFIGURE_CMC=yes
INSTALL_CONFIGURE_SMTP_NOTIFICATION=yes
INSTALL_CONFIG_FILE=./CloudianInstallConfiguration.txt
INSTALL_CRED_SLAVES_PER_DC=2
INSTALL_HOSTS_FILE=hosts.cloudian

''')

    cic.write('''cloudian_s3_domain=%(domain)s
cloudian_cmc_domain=%(cmc-endpoint)s
cloudian_admin_host=%(admin-endpoint)s

''' % input['cluster'])

    cic.write('''cloudian_cassandra_default_node_datacenter=%(name)s:%(name)s
''' % input['cluster']['regions'][0]['data-centers'][0])

    cic.write('''cloudian_cassandra_network_interface=%(name)s
cloudian_credentials_network_interface=%(name)s
cloudian_hyperstore_cassandra_interface=%(name)s
cloudian_internal_network_interface=%(name)s
cloudian_puppet_network_interface=%(name)s
cloudian_qos_network_interface=%(name)s
cloudian_redis_monitor_network_interface=%(name)s

''' % [ iface for iface in input['cluster']['network-config'] if iface['use'] == 'backend' ][0])

    data = {
        'region-labels': ','.join([ region['name'] for region in input['cluster']['regions'] ]),
        'regions': ','.join([ "region%d" % (i + 1) for i in range(len(input['cluster']['regions'])) ]),
    }

    cic.write('''cloudian_cluster_default_region=region1
cloudian_cluster_region_labels=%(region-labels)s
cloudian_cluster_regions=%(regions)s

cloudian_configure_dnsmasq=no

''' % data)

    # survey.csv
    csv_rows = []

    for index, region in enumerate(input['cluster']['regions']):
        # more CIC
        region['number'] = index + 1
        region['ntp-server-list'] = ','.join(region['ntp-servers'])
        region['end-points'] = ','.join(region['s3-endpoints'])
        # TODO: 3 is hardcoded
        region['replication'] = ','.join([ "%s:3" % data_center['name']
                                           for data_center in region['data-centers'] ])
        # [0]=\"DC10\" [1]=\"DC3\"
        region['dcs'] = ' '.join([ '[%d]=\\"%s\\"' % (index, data_center['name'])
                                   for index, data_center in enumerate(region['data-centers']) ])

        cic.write('''###########
# Region %(number)d: %(name)s
cloudian_cluster_regionname_region%(number)d=%(name)s
cloudian_datacenters_region%(number)d=(%(dcs)s)

cloudian_accountinfo_replication_region%(number)d=%(replication)s
cloudian_data_replication_region%(number)d=%(replication)s
cloudian_monitoring_replication_region%(number)d=%(replication)s
cloudian_reports_replication_region%(number)d=%(replication)s

cloudian_ntp_time_server_region%(number)d=%(ntp-server-list)s
cloudian_s3_domain_region%(number)d=%(end-points)s
cloudian_s3_website_endpoint_region%(number)d=%(website-endpoint)s

''' % region)

        region_network_config = deepcopy(cluster_network_config)
        # pprint(region_network_config)
        # print

        for dc_config in region['data-centers']:
            dc_name = dc_config['name']

            dc_network_config = deepcopy(region_network_config)
            recursive_update(dc_network_config, dc_config.get('network-config', []))
            # pprint(dc_network_config)
            # print

            # Ansible expects nodes declared as 'hosts'
            dc = dict(hosts={})

            for node in dc_config['nodes']:
                node_network_config = deepcopy(dc_network_config)
                # pprint(node_network_config)
                # print

                # pprint(node)
                # print

                # update(node_network_config, node)
                # pprint(node_network_config)
                # print
                # TODO:
                # node_network_config['ansible_node'] =

                # pprint(node_network_config)

                node_info = convert(node_network_config, node)
                # pprint(node_info)
                dc['hosts'][node['name']] = node_info

                if node.get('installer-node', False):
                    output['installer-node'] = { 'hosts': { node['name']: {} } }

                if 'ipmi' in node_network_config:
                    output['all']['vars']['cfg_ipmi'] = True

                csv_rows.append([ region['name'], node['name'], node_info['net_frontend_addr'], dc_name, dc_name,
                                  node_info['backend_iface'] ])

        output['cloudian']['children'][dc_name] = dc

    open(sys.argv[2], 'w+').write(yaml.dump(output, default_flow_style=False))
    csv.writer(open('roles/pre-installer/files/survey.csv', 'w+')).writerows(csv_rows)



if __name__ == '__main__':
    main()
