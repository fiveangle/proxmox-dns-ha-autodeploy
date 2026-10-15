# shellcheck shell=bash
# Shared set-up for the helper scripts: load the libraries and the saved deployment answers,
# then switch LXC access to direct SSH (works for single- and two-host deployments alike).
set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
for _lib in common node prompts technitium keepalived extras finalize; do
  # shellcheck disable=SC1090
  source "$SCRIPT_DIR/lib/$_lib.sh"
done
trap on_error ERR

HELPER_CONFIG=$CONFIG_FILE_DEFAULT
helper_args=()
while (( $# )); do
  case "$1" in
    --config) HELPER_CONFIG=${2:?--config needs a file}; shift 2 ;;
    *) helper_args+=("$1"); shift ;;
  esac
done
set -- "${helper_args[@]+"${helper_args[@]}"}"

[[ $EUID -eq 0 ]] || die "Run as root"
NONINTERACTIVE=1
load_config "$HELPER_CONFIG" >/dev/null
ADMIN_PASSWORD=$(cred_get ADMIN_PASSWORD)
VRRP_AUTH_PASS=$(cred_get VRRP_AUTH_PASS)
# shellcheck source=../lib/remote.sh
source "$SCRIPT_DIR/lib/remote.sh"

# node_reachable N — SSH answers within the connect timeout
node_reachable() { lxc_ssh "$1" true 2>/dev/null; }
