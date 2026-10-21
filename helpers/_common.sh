# shellcheck shell=bash
# Shared set-up for the helper scripts: load the libraries and the saved deployment answers,
# then switch LXC access to direct SSH (works however many Proxmox hosts the nodes run on).
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

# config_set KEY VALUE — rewrite (or append) one line of the answers file.
config_set() {
  local key=$1 line tmp
  printf -v line '%s=%q' "$key" "$2"
  tmp=$(mktemp "$HELPER_CONFIG.XXXXXX")
  if grep -q "^$key=" "$HELPER_CONFIG"; then
    # ENVIRON, not -v: awk -v would interpret the backslashes printf %q may produce.
    K=$key L=$line awk 'index($0, ENVIRON["K"] "=") == 1 { print ENVIRON["L"]; next } { print }' "$HELPER_CONFIG" >"$tmp"
  else
    cat "$HELPER_CONFIG" >"$tmp"; echo "$line" >>"$tmp"
  fi
  chmod 600 "$tmp"; mv "$tmp" "$HELPER_CONFIG"
}

login_all() {
  local n
  for n in $(all_nodes); do
    node_reachable "$n" || die "$(node_var "$n" HOST) is not reachable over SSH - $(all_word) nodes are needed"
    detect_tech_url "$n"
    tech_login "$n" || die "Admin login failed on $(node_var "$n" HOST) (see reset-admin.sh)"
  done
  trap 'tech_logout' EXIT
}

# delete_zone_everywhere ZONE — export ns1's copy to zone-backups/, then delete the zone on every server.
delete_zone_everywhere() {
  local z=$1 dir file n t
  if [[ -n "$(zone_type 1 "$z")" ]]; then
    dir="$STATE_DIR/zone-backups"; install -d -m 700 "$dir"
    file="$dir/$z-$(date +%Y%m%d-%H%M%S).zone"
    lxc_query 1 curl -fsSk -m 30 -H "Authorization: Bearer ${TOKENS[1]}" \
      "$(tech_url 1)/api/zones/export?zone=$(jq -rn --arg z "$z" '$z|@uri')" >"$file" \
      || { rm -f "$file"; die "Could not export $z from $CFG_NS1 - nothing deleted"; }
    chmod 600 "$file"
    ok "Exported $z to $file (import it in the web UI to restore)"
  fi
  # The secondaries' copies go first, so none asks ns1 for a zone that no longer exists.
  for n in $(all_nodes | sort -rn); do
    t=$(zone_type "$n" "$z")
    [[ -n "$t" ]] || continue
    tech_api "$n" zones/delete "zone=$z" >/dev/null
    ok "$(node_var "$n" NS): deleted $t zone $z"
  done
}
