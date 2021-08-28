#!/bin/bash
set -ueo pipefail
trap "if ! diff <(sops -d terraform.tfstate.enc) terraform.tfstate >/dev/null 2>&1; then sops -e terraform.tfstate > terraform.tfstate.enc; fi; rm -f terraform.tfstate terraform.tfstate.backup" EXIT

sops -d terraform.tfstate.enc > terraform.tfstate
terraform "$@"
