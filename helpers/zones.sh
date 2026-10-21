#!/usr/bin/env bash
# Manage additional local zones. A new one is a Conditional Forwarder zone on ns1 (records you
# add are answered locally, names not in the zone are forwarded upstream) with a
# SecondaryForwarder copy on each secondary that follows ns1 by zone transfer + NOTIFY - the
# same set-up as a public main zone. A zone already on ns1 (e.g. made in the web UI) is adopted
# as is: a Forwarder zone as above, a Primary zone with Secondary copies. The zone list is kept
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
# every server (so the secondaries got it by zone transfer), and a name not in the zone must get the same
# answer code as from the upstream resolver (Forwarder) or NXDOMAIN (Primary).
check_zone() {
  local z=$1 n i ip name="_zones-check-$RANDOM.$z" val probe up got primary=no
  [[ "$(zone_type 1 "$z")" == Primary ]] && primary=yes
  val="check-$(rand_alnum 12)"
  tech_api 1 zones/records/add "zone=$z" "domain=$name" type=TXT "text=$val" ttl=60 >/dev/null
  for n in $(all_nodes); do
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
    for n in $(all_nodes); do
      got=$(rcode_of "$(node_ip "$n")" "$probe")
      [[ "$got" == NXDOMAIN ]] || die "$(node_var "$n" NS): $probe answered ${got:-nothing}, expected NXDOMAIN"
    done
    ok "$z: answered by $(and_list $(ns_names $(all_nodes))) (Primary: names not in the zone get NXDOMAIN)"
    return 0
  fi
  up=$(rcode_of "${CFG_UPSTREAM_IPS%% *}" "$probe")
  for n in $(all_nodes); do
    got=$(rcode_of "$(node_ip "$n")" "$probe")
    [[ -n "$got" && "$got" == "$up" ]] || die "$(node_var "$n" NS): $probe answered $got, upstream $up - not forwarded"
  done
  ok "$z: answered locally by $(and_list $(ns_names $(all_nodes))); names not in the zone go upstream ($up)"
}

cmd_list() {
  local z n l1 extra
  local -a zl=()
  login_all
  for n in $(all_nodes); do zl[n]=$(tech_api "$n" zones/list); done
  l1=${zl[1]}
  printf '\n  %s%-30s %-8s %-30s' "$C_BOLD" Zone Role "Type ($CFG_NS1/copies)"
  for n in $(all_nodes); do printf ' %-10s' "$(node_var "$n" NS)"; done
  printf ' %s%s\n' State "$C_RESET"
  row() {  # row ZONE ROLE
    local t1 tc="" t s state="" m serial=()
    for m in $(all_nodes); do
      t=$(jq -r --arg z "$1" '.zones[] | select(.name == $z) | .type' <<<"${zl[m]}")
      serial[m]=$(jq -r --arg z "$1" '.zones[] | select(.name == $z) | .soaSerial // empty' <<<"${zl[m]}")
      if (( m == 1 )); then t1=$t
      elif [[ -z "$tc" ]]; then tc=${t:--}
      elif [[ "$tc" != "${t:--}" ]]; then tc=mixed
      fi
      if [[ -z "$state" && -z "$t" ]]; then state="${C_RED}missing on $(node_var "$m" NS)${C_RESET}"
      elif [[ -z "$state" && $m != 1 && "$(jq -r --arg z "$1" '.zones[] | select(.name == $z) | .syncFailed // false' <<<"${zl[m]}")" == true ]]; then
        state="${C_RED}transfer failing on $(node_var "$m" NS)${C_RESET}"
      fi
    done
    if [[ -z "$state" ]]; then
      state="${C_GREEN}in sync${C_RESET}"
      for m in $(secondary_nodes); do [[ "${serial[m]}" == "${serial[1]}" ]] || state="${C_YELLOW}syncing${C_RESET}"; done
    fi
    printf '  %-30s %-8s %-30s' "$1" "$2" "${t1:--}/$tc"
    for m in $(all_nodes); do printf ' %-10s' "${serial[m]:--}"; done
    printf ' %s\n' "$state"
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
    info "A Primary or Forwarder zone among them can be adopted (and copied to the secondaries) with: zones.sh add <zone>"
  fi
  echo
}

cmd_add() {
  (( ${#ZONES[@]} )) || usage
  ZONES=($(normalize_zones "${ZONES[*]}"))   # also splits "a.com,b.com"
  v_extra_zones "${ZONES[*]}" || die "Nothing was changed"
  local z new
  login_all
  for z in "${ZONES[@]}"; do ensure_extra_zone "$z"; done
  wait_for_zone_sync "${ZONES[@]}"
  for z in "${ZONES[@]}"; do check_zone "$z"; done

  new=$(normalize_zones "${CFG_EXTRA_ZONES:-} ${ZONES[*]}")
  new=$(tr ' ' '\n' <<<"$new" | awk 'NF && !seen[$0]++' | paste -sd' ')
  if [[ "$new" != "${CFG_EXTRA_ZONES:-}" ]]; then
    config_set CFG_EXTRA_ZONES "$new"
    ok "CFG_EXTRA_ZONES in $HELPER_CONFIG: $new"
  fi
  info "Add records to these zones on $CFG_NS1 ($(node_ip 1)) only; the secondaries follow within ~10s"
}

cmd_remove() {
  (( ${#ZONES[@]} == 1 )) || usage
  local z=${ZONES[0]}
  [[ " ${CFG_EXTRA_ZONES:-} " == *" $z "* ]] \
    || die "$z is not in CFG_EXTRA_ZONES - only zones added with zones.sh/deploy.sh are removed here"
  login_all
  if [[ "$YES" != yes ]]; then
    answer=""; NONINTERACTIVE=0
    ask_yn answer "Delete zone $z and all its records from $(and_list $(ns_names $(all_nodes)))?" no
    [[ "$answer" == yes ]] || exit 0
  fi
  delete_zone_everywhere "$z"
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
