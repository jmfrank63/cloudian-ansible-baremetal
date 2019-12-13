#! /bin/bash

set -eu

if [ $# -eq 0 ] || [ $1 != '--retry' ]; then
    rm -frv bin lib local share
fi

/usr/bin/python2 -m virtualenv --system-site-packages --prompt '(venv: magic-confiblugator) ' .

source bin/activate
pip install -r requirements.txt
