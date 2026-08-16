#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

set --
source "${REPO_ROOT}/source/usr/local/emhttp/plugins/novidio-vgpu-driver/include/exec.sh"

SETTINGS_FILE="${TMP_DIR}/settings.cfg"
VGPU_UNLOCK_CONFIG="${TMP_DIR}/vgpu_unlock/config.toml"

printf '%s\n' \
  'driver_version=latest' \
  'update_check=false' \
  'update_check=true' \
  'vgpu_unlock=false' > "${SETTINGS_FILE}"

change_vgpu_unlock true >/dev/null

[ "$(get_vgpu_unlock)" = "true" ]
[ "$(grep -c '^vgpu_unlock=' "${SETTINGS_FILE}")" -eq 1 ]
grep -qx 'unlock = true' "${VGPU_UNLOCK_CONFIG}"

set_setting update_check false
[ "$(grep -c '^update_check=' "${SETTINGS_FILE}")" -eq 1 ]
grep -qx 'update_check=false' "${SETTINGS_FILE}"

change_vgpu_unlock false >/dev/null
[ "$(get_vgpu_unlock)" = "false" ]
grep -qx 'unlock = false' "${VGPU_UNLOCK_CONFIG}"

if change_vgpu_unlock invalid >/dev/null 2>&1; then
  echo "change_vgpu_unlock accepted an invalid value" >&2
  exit 1
fi

echo "exec settings tests passed"
