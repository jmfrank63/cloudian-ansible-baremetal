#! /bin/bash

set -eu

rm -rf lib/python2.7/site-packages/ansible*
pip install --ignore-installed ansible==2.5.1
