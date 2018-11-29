#! /bin/bash

set -eu

rm -frv bin lib share

/usr/bin/python2 -m virtualenv --system-site-packages --prompt '(venv: magic-confiblugator) ' .

source bin/activate
pip install -r requirements.txt
