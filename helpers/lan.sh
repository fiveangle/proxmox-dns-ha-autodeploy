#!/usr/bin/env bash
# LAN hostnames: forward a local domain (e.g. lan.example.com) - and, optionally, reverse lookups
# for the LXC subnet - to the router/DHCP server, which answers for its DHCP clients. The LAN
# zone is a Conditional Forwarder zone on ns1 with a SecondaryForwarder copy on each secondary; the
# settings are kept in CFG_LAN_DNS / CFG_LAN_DOMAIN / CFG_LAN_PTR, so deploy.sh re-runs keep them.
#
# Usage: lan.sh [--config FILE] [status]                        checks + DHCP server settings
#        lan.sh [--config FILE] set ROUTER_IP [DOMAIN] [--no-ptr]  turn on or change
#        lan.sh [--config FILE] off [--yes]                     turn off (exports the zone first)
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

usage() {
  cat >&2 <<EOF
Usage: lan.sh [--config FILE] [status]
       lan.sh [--config FILE] set ROUTER_IP [DOMAIN] [--no-ptr]
       lan.sh [--config FILE] off [--yes]
EOF
  exit 2
}
cmd=${1:-status}; shift || true
YES=no PTR=yes; declare -a ARGS=()
for a in "$@"; do
  case "$a" in --yes) YES=yes ;; --no-ptr) PTR=no ;; -*) die "Unknown option: $a" ;; *) ARGS+=("$a") ;; esac
done

# lan_checks — the LAN checks against every server; exit 1 when one fails.
lan_checks() {
  local n
  lan_probe
  VERIFY_FAIL=0
  for n in $(all_nodes); do
    printf '  %s%s (%s)%s\n' "$C_BOLD" "$(node_var "$n" NS)" "$(node_ip "$n")" "$C_RESET"
    verify_lan "$(node_ip "$n")"
  done
  lan_loop_hint
  (( VERIFY_FAIL == 0 )) || { err "$VERIFY_FAIL LAN check(s) failed"; exit 1; }
  ok "LAN hostnames resolve through $(and_list $(ns_names $(all_nodes)))"
}

# apply — bring every server in line with the CFG_LAN_* values, removing the zones the old
# values needed and the new ones do not, then save the values.
apply() {
  local old_domain=$1 old_rz=$2
  login_all
  [[ -n "$old_domain" && "$old_domain" != "${CFG_LAN_DOMAIN:-}" ]] && delete_zone_everywhere "$old_domain"
  [[ -n "$old_rz" && -z "$(reverse_zone)" ]] && delete_zone_everywhere "$old_rz"
  configure_zones                  # idempotent: creates/converts what is missing, then waits for the copies
  config_set CFG_LAN_DNS "$CFG_LAN_DNS"
  config_set CFG_LAN_DOMAIN "$CFG_LAN_DOMAIN"
  config_set CFG_LAN_PTR "$CFG_LAN_PTR"
  ok "Saved CFG_LAN_DNS / CFG_LAN_DOMAIN / CFG_LAN_PTR in $HELPER_CONFIG"
}

cmd_status() {
  section "LAN hostnames"
  if [[ -z "$CFG_LAN_DNS" ]]; then
    info "Off. Turn on with: lan.sh set <router-ip> [domain]   (default domain: lan.${CFG_ZONE:-home.arpa})"
    return 0
  fi
  info "*.$CFG_LAN_DOMAIN$([[ $CFG_LAN_PTR == yes ]] && echo " and reverse lookups for $(cidr_network "$CFG_IP1")") -> $CFG_LAN_DNS"
  lan_dhcp_instructions; echo
  lan_checks
}

cmd_set() {
  (( ${#ARGS[@]} >= 1 && ${#ARGS[@]} <= 2 )) || usage
  local old_domain=$CFG_LAN_DOMAIN old_rz
  old_rz=$(reverse_zone)
  CFG_LAN_DNS=${ARGS[0]}
  CFG_LAN_DOMAIN=$(normalize_zones "${ARGS[1]:-${CFG_LAN_DOMAIN:-lan.${CFG_ZONE:-home.arpa}}}")
  CFG_LAN_PTR=$PTR
  v_lan_dns "$CFG_LAN_DNS" || die "Not a usable router/DHCP server address: $CFG_LAN_DNS - nothing was changed"
  v_lan_domain "$CFG_LAN_DOMAIN" || die "Nothing was changed"
  [[ -n "$(dq @"$CFG_LAN_DNS" -x "$CFG_LAN_DNS" | grep -o 'status: [A-Z]*')" ]] \
    || die "No DNS server answers on $CFG_LAN_DNS - nothing was changed"
  apply "$old_domain" "$old_rz"
  lan_dhcp_instructions; echo
  lan_checks
}

cmd_off() {
  (( ${#ARGS[@]} == 0 )) || usage
  [[ -n "$CFG_LAN_DNS" ]] || { info "LAN hostnames are already off"; return 0; }
  local old_domain=$CFG_LAN_DOMAIN old_rz
  old_rz=$(reverse_zone)
  if [[ "$YES" != yes ]]; then
    answer=""; NONINTERACTIVE=0
    ask_yn answer "Stop forwarding $CFG_LAN_DOMAIN to $CFG_LAN_DNS (deletes that zone on $(all_word) servers)?" no
    [[ "$answer" == yes ]] || exit 0
  fi
  CFG_LAN_DNS=""; CFG_LAN_DOMAIN=""; CFG_LAN_PTR=no
  apply "$old_domain" "$old_rz"
  ok "LAN hostnames off$([[ -n $(reverse_zone) ]] && echo "; reverse zone $(reverse_zone) is a Primary zone again")"
}

case "$cmd" in
  status) cmd_status ;;
  set)    cmd_set ;;
  off)    cmd_off ;;
  -h|--help|help) usage ;;
  *) die "Unknown command: $cmd (status | set | off)" ;;
esac
