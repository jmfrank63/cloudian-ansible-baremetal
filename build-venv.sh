#! /bin/bash

set -eu

if [ $# -eq 0 ] || [ $1 != '--retry' ]; then
    rm -frv bin lib local share
fi

/usr/bin/python2 -m virtualenv --system-site-packages --prompt '(venv: magic-confiblugator) ' .

# there's a 'bug' in bin/activate that references PS1 in situations where it's not defined
set +u
source bin/activate
set -u

pip install -r requirements.txt
