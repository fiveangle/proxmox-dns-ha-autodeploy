#!/usr/bin/env bash
# Manage additional local zones. A new one is a Conditional Forwarder zone on ns1 (records you
# add are answered locally, names not in the zone are forwarded upstream) with a
# SecondaryForwarder copy on ns2 that follows ns1 by zone transfer + NOTIFY - the same set-up
# as a public main zone. A zone already on ns1 (e.g. made in the web UI) is adopted as is:
# a Forwarder zone as above, a Primary zone with a Secondary copy on ns2. The zone list is kept
# in CFG_EXTRA_ZONES, so deploy.sh re-runs keep it.
#
# Usage: zones.sh [--config FILE] list
#        zones.sh [--config FILE] add ZONE [ZONE...]     (adopts a Primary/Forwarder zone on ns1)
#        zones.sh [--config FILE] remove ZONE [--yes]    (exports the zone file first)
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

usage() {
  cat >&2 <<EOF
Usage: zones.sh [--config FILE] list
       zones.sh [--config FILE] add ZONE [ZONE...]
       zones.sh [--config FILE] remove ZONE [--yes]
EOF
  exit 2
}
cmd=${1:-list}; shift || true
YES=no; declare -a ZONES=()
for a in "$@"; do case "$a" in --yes) YES=yes ;; -*) die "Unknown option: $a" ;; *) ZONES+=("$(normalize_zones "$a")") ;; esac; done

# Proves the whole path for a zone: a temporary TXT record written on ns1 must be answered by
# both servers (so ns2 got it by zone transfer), and a name not in the zone must get the same
# answer code as from the upstream resolver (Forwarder) or NXDOMAIN (Primary).
check_zone() {
  local z=$1 n i ip name="_zones-check-$RANDOM.$z" val probe up got primary=no
  [[ "$(zone_type 1 "$z")" == Primary ]] && primary=yes
  val="check-$(rand_alnum 12)"
  tech_api 1 zones/records/add "zone=$z" "domain=$name" type=TXT "text=$val" ttl=60 >/dev/null
  for n in 1 2; do
    ip=$(node_ip "$n")
    for (( i = 0; i < 15; i++ )); do
      [[ "$(dq +short +norecurse @"$ip" "$name" TXT)" == "\"$val\"" ]] && break
      sleep 2
    done
    if (( i == 15 )); then
      tech_api 1 zones/records/delete "zone=$z" "domain=$name" type=TXT "text=$val" >/dev/null || true
      die "$(node_var "$n" NS) does not answer records of $z"
    fi
  done
  tech_api 1 zones/records/delete "zone=$z" "domain=$name" type=TXT "text=$val" >/dev/null
  probe="no-such-host-$RANDOM.$z"
  if [[ "$primary" == yes ]]; then
    for n in 1 2; do
      got=$(rcode_of "$(node_ip "$n")" "$probe")
      [[ "$got" == NXDOMAIN ]] || die "$(node_var "$n" NS): $probe answered ${got:-nothing}, expected NXDOMAIN"
    done
    ok "$z: answered by $CFG_NS1 and $CFG_NS2 (Primary: names not in the zone get NXDOMAIN)"
    return 0
  fi
  up=$(rcode_of "${CFG_UPSTREAM_IPS%% *}" "$probe")
  for n in 1 2; do
    got=$(rcode_of "$(node_ip "$n")" "$probe")
    [[ -n "$got" && "$got" == "$up" ]] || die "$(node_var "$n" NS): $probe answered $got, upstream $up - not forwarded"
  done
  ok "$z: answered locally by $CFG_NS1 and $CFG_NS2; names not in the zone go upstream ($up)"
}

cmd_list() {
  local z l1 l2 t1 t2 s1 s2 sf extra
  login_both
  l1=$(tech_api 1 zones/list); l2=$(tech_api 2 zones/list)
  printf '\n  %s%-30s %-8s %-30s %-8s %-8s %s%s\n' "$C_BOLD" Zone Role "Type ($CFG_NS1/$CFG_NS2)" "Serial1" "Serial2" State "$C_RESET"
  row() {  # row ZONE ROLE
    t1=$(jq -r --arg z "$1" '.zones[] | select(.name == $z) | .type' <<<"$l1")
    t2=$(jq -r --arg z "$1" '.zones[] | select(.name == $z) | .type' <<<"$l2")
    s1=$(jq -r --arg z "$1" '.zones[] | select(.name == $z) | .soaSerial // empty' <<<"$l1")
    s2=$(jq -r --arg z "$1" '.zones[] | select(.name == $z) | .soaSerial // empty' <<<"$l2")
    sf=$(jq -r --arg z "$1" '.zones[] | select(.name == $z) | .syncFailed // false' <<<"$l2")
    local state
    if [[ -z "$t1" ]]; then state="${C_RED}missing on $CFG_NS1${C_RESET}"
    elif [[ -z "$t2" ]]; then state="${C_RED}missing on $CFG_NS2${C_RESET}"
    elif [[ "$sf" == true ]]; then state="${C_RED}transfer failing${C_RESET}"
    elif [[ "$s1" == "$s2" ]]; then state="${C_GREEN}in sync${C_RESET}"
    else state="${C_YELLOW}syncing${C_RESET}"
    fi
    printf '  %-30s %-8s %-30s %-8s %-8s %s\n' "$1" "$2" "${t1:--}/${t2:--}" "${s1:--}" "${s2:--}" "$state"
  }
  [[ -n "$CFG_ZONE" ]] && row "$CFG_ZONE" main
  [[ -n "$(reverse_zone)" ]] && row "$(reverse_zone)" reverse
  for z in ${CFG_EXTRA_ZONES:-}; do row "$z" extra; done
  [[ -n "${CFG_LAN_DNS:-}" ]] && row "$CFG_LAN_DOMAIN" lan
  # User zones on ns1 that have no copy managed by this deployment (internal zones excluded).
  extra=$(jq -r '.zones[] | select(.internal | not) | .name' <<<"$l1" | grep -vxF -f <(managed_zones; echo) || true)
  if [[ -n "$extra" ]]; then
    echo; warn "Zones on $CFG_NS1 not managed here (not replicated by this tool):"
    for z in $extra; do
      printf '    %-34s %s\n' "$z" "$(jq -r --arg z "$z" '.zones[] | select(.name == $z) | .type' <<<"$l1")"
    done
    info "A Primary or Forwarder zone among them can be adopted (and copied to $CFG_NS2) with: zones.sh add <zone>"
  fi
  echo
}

cmd_add() {
  (( ${#ZONES[@]} )) || usage
  ZONES=($(normalize_zones "${ZONES[*]}"))   # also splits "a.com,b.com"
  v_extra_zones "${ZONES[*]}" || die "Nothing was changed"
  local z new
  login_both
  for z in "${ZONES[@]}"; do ensure_extra_zone "$z"; done
  wait_for_zone_sync "${ZONES[@]}"
  for z in "${ZONES[@]}"; do check_zone "$z"; done

  new=$(normalize_zones "${CFG_EXTRA_ZONES:-} ${ZONES[*]}")
  new=$(tr ' ' '\n' <<<"$new" | awk 'NF && !seen[$0]++' | paste -sd' ')
  if [[ "$new" != "${CFG_EXTRA_ZONES:-}" ]]; then
    config_set CFG_EXTRA_ZONES "$new"
    ok "CFG_EXTRA_ZONES in $HELPER_CONFIG: $new"
  fi
  info "Add records to these zones on $CFG_NS1 ($(node_ip 1)) only; $CFG_NS2 follows within ~10s"
}

cmd_remove() {
  (( ${#ZONES[@]} == 1 )) || usage
  local z=${ZONES[0]}
  [[ " ${CFG_EXTRA_ZONES:-} " == *" $z "* ]] \
    || die "$z is not in CFG_EXTRA_ZONES - only zones added with zones.sh/deploy.sh are removed here"
  login_both
  if [[ "$YES" != yes ]]; then
    answer=""; NONINTERACTIVE=0
    ask_yn answer "Delete zone $z and all its records from $CFG_NS1 and $CFG_NS2?" no
    [[ "$answer" == yes ]] || exit 0
  fi
  delete_zone_pair "$z"
  config_set CFG_EXTRA_ZONES "$(tr ' ' '\n' <<<"$CFG_EXTRA_ZONES" | grep -vxF "$z" | paste -sd' ' || true)"
  ok "Removed $z from CFG_EXTRA_ZONES in $HELPER_CONFIG"
}

case "$cmd" in
  list)   cmd_list ;;
  add)    cmd_add ;;
  remove) cmd_remove ;;
  -h|--help|help) usage ;;
  *) die "Unknown command: $cmd (list | add | remove)" ;;
esac
