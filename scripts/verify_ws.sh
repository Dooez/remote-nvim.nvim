#!/usr/bin/env bash

set -eoE pipefail

WORKSPACE_NAME="${1}"
VERSION="${2}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REQUIRED_DIRS=(
    ".cache"
	".local"
    ".data"
)
WORKSPACES="$(realpath -m "${SCRIPTS_DIR}/../workspaces/${WORKSPACE_NAME}")"
BIN="$(realpath -m "${SCRIPTS_DIR}/../nvim-downloads/${VERSION}")"

if [[ ! -d "${WORKSPACES}" ]]; then
		printf("false")
		exit 1
fi
if [[ ! -d "${WORKSPACES}/.cache" ]]; then
		printf("false")
		exit 1
fi
if [[ ! -d "${WORKSPACES}/.config" ]]; then
		printf("false")
		exit 1
fi
if [[ ! -d "${WORKSPACES}/.local" ]]; then
		printf("false")
		exit 1
fi
if [[ ! -d "${BIN}" ]]; then
		printf("false")
		exit 1
fi
if [[ ! ( -f "${BIN}/bin/nvim" && -x "${BIN}/bin/nvim" ) ]]; then
		printf("false")
		exit 1
fi

printf("true")



