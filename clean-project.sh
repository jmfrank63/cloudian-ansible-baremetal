#! /bin/bash

set -eu

if [ "$#" -ne 1 -a "$#" -ne 2 ]; then
    echo "Usage: $0 [--really-clean] [project_dir]"
    exit 1
fi

target='clean'

if [ "$1" == '--really-clean' ]; then
    target='really-clean'

    shift
fi

project="$1"

make PROJECT_DIR="$project" $target
