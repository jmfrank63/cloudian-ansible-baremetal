#!/usr/bin/env python

import subprocess
import os
import argparse

parser = argparse.ArgumentParser()
parser.add_argument('-c', '--count', action='store_true', required=False, dest='count')
parser.add_argument('--list', action='store_true', required=False, dest='list')
parser.set_defaults(count=False)
args = parser.parse_args()

# Make sure the DHCP lease contains DHCP_HOSTNAME=<string> on the DHCP enabled interface of nodes you want to manage (default is "node" here. Cloudian Appliance default is "cloudian-node")
bash_out = subprocess.Popen("cat /var/lib/dhcpd/dhcpd.leases | perl -e 'while(<>) {$_ =~ m/lease ([0-9.]+)/; $addr=$1; if($_ =~ m/client-hostname \".*/ && not($1 =~ m/QCT/)) {print \"$addr\n\"}}' | sort -u", shell=True, stdout=subprocess.PIPE).stdout.read()

servers = {
    'cloudian': {
        'hosts': []
    },
    'local': {
        'hosts': ['127.0.0.1']
    }
}

bash_out_list = str(bash_out).split('\n')
server_list = []

for line in bash_out_list:
    server_list.append(line.replace('\'', '').replace("b", ''))

server_list.remove('')

for server in server_list:
    if os.system("timeout 0.25 ping -c1 "+server+">/dev/null") == 0:
        servers['cloudian']['hosts'].append(server)

if args.count:
    print(len(servers['cloudian']['hosts']))
else:
    print(servers)
