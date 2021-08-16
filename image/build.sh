#!/bin/bash

SCRIPT_DIR=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)

PACKER_VAR_FILES=${SCRIPT_DIR}/vars.json make -C ${SCRIPT_DIR}/image-builder/images/capi build-hcloud-ubuntu-2004
