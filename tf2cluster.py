#! /usr/bin/env python2

# the good thing about standards...
import json
import yaml
# from pprint import pprint
import sys

# this tool fixes the ouput of cluster_config2tab.py
# that tool can only assume the ansible_host is going to be the same as (one of)
# the frontend interface(s), but our terraform+lxd system add an interface which
# gets a random IP via DHCP, so we read the terraform state file and fix that


def main ():
    if len(sys.argv) != 4:
        print "Usage: %s [inventory.yaml] [terraform.tfstate] [fixed-inventory.yaml]" % sys.argv[0]
        print
        print "Fixes inventory with the dynamic IPs so Ansible can connect the via ssh on the provision interface."
        sys.exit(1)

    terraform = json.load(open(sys.argv[2]))
    cluster = yaml.load(open(sys.argv[1]))

    tf_nodes = { name.replace('lxd_container.', ''): node
                 for name, node in terraform['modules'][0]['resources'].items() }

    for dc, dc_config in cluster['cloudian']['children'].items():
        for node, node_config in dc_config['hosts'].items():
            # pprint( (node_config, tf_nodes[node]['primary']['attributes']['ip_address']) )
            # find the node def in terraform and update the ansible_host item in node_config
            # json loads in unicode, so encode
            node_config['ansible_host'] = tf_nodes[node]['primary']['attributes']['ip_address'].encode()

    yaml.dump(cluster, open(sys.argv[3], 'w+'), default_flow_style=False)


if __name__ == '__main__':
    main()
