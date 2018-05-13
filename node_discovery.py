#!/usr/bin/env python

# Simple node discovery based on identifying chassis. Builds an inventory list

import subprocess
import os
import json
from pick import pick
import ConfigParser

topology = "inventory/topology"
dhcp_inventory = "./inventory/dhcp_inventory.py"
inventory = subprocess.Popen(dhcp_inventory, shell=True, stdout=subprocess.PIPE).stdout.read()

json_str = inventory.replace("'", "\"")
hosts = json.loads(json_str)

config = ConfigParser.ConfigParser(allow_no_value=True)
config.read(topology)

regionconf = dict(config.items('region-1:children'))
datacenters = sorted(regionconf.keys())
#datacenters.append('ALL')  

# get Datacenter
title = 'Select Datacenter:'
options = datacenters
datacenter, index = pick(options, title)

datacenter = datacenter.upper()

datacenterconf = dict(config.items(datacenter))
dcnodes = sorted(datacenterconf.keys())

newhosts = {}
DEVNULL = open(os.devnull, 'w')
for addr in hosts['cloudian']['hosts']:

  ansible = subprocess.Popen(['ansible-playbook','node_discovery.yml','-i', dhcp_inventory, '--limit', addr], stdout=DEVNULL, stderr=DEVNULL)

  title = 'Watch chassis LEDs. Which node is blinking?'
  options = dcnodes
  node, index = pick(options, title)

  newhosts[node] = addr
  dcnodes.remove(node)
  ansible.terminate()
  if not dcnodes:
    break
  

# print final host config
print "Add/replace the following in your", topology, "file:\n"
print "[cloudian]"
for k, v in sorted(newhosts.iteritems()):
  print k, "ansible_host={}".format(v)
