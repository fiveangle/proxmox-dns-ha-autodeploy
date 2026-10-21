#!/usr/bin/env bash
# Show the health of the Technitium HA servers: VIP holder, keepalived, container, DNS answers.
# Usage: status.sh [--config FILE]     Exit code: 0 healthy, 1 problems found.
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

problems=0
flag() { problems=$((problems+1)); printf '%s%s%s' "$C_RED" "$1" "$C_RESET"; }
good() { printf '%s%s%s' "$C_GREEN" "$1" "$C_RESET"; }

section "Technitium HA status - VIP $CFG_VIP"
holders=$(vip_holders 2>/dev/null || true)
printf '  %-28s ' "VIP holder"
case "$holders" in
  [1-9]) good "$(node_var "$holders" HOST)"; [[ "$holders" != 1 ]] && printf ' (failback to %s pending or %s unhealthy)' "$CFG_HOST1" "$CFG_HOST1" ;;
  "")  flag "NOBODY - DNS on the VIP is down" ;;
  *)   flag "SEVERAL NODES: $(for n in $holders; do printf '%s ' "$(node_var "$n" HOST)"; done)(split brain)" ;;
esac
echo
probe_name=localhost; [[ -n "$CFG_ZONE" ]] && probe_name="$CFG_NS1.$CFG_ZONE"
a=$(dq +short @"$CFG_VIP" "$probe_name" A | tail -1)
printf '  %-28s ' "DNS via VIP"; [[ -n "$a" ]] && good "answers ($a)" || flag "no answer"; echo

for n in $(all_nodes); do
  printf '\n  %s%s%s (%s, VMID %s on %s)\n' "$C_BOLD" "$(node_var "$n" HOST)" "$C_RESET" "$(node_ip "$n")" \
    "$(node_var "$n" VMID)" "$(node_label "$n")"
  if ! node_reachable "$n"; then printf '    %-26s ' "SSH"; flag "unreachable"; echo; continue; fi
  ka=$(lxc_query "$n" systemctl is-active keepalived 2>/dev/null || true)
  st=$(ka_state "$n")
  printf '    %-26s ' "keepalived"; [[ "$ka" == active ]] && good "active, $st" || flag "$ka"; echo
  hv=$(handover_value "$n")
  if [[ "$hv" =~ ^-[0-9]+$ ]]; then
    printf '    %-26s ' "VIP handover"; flag "active (priority lowered by ${hv#-}) - an update/deploy was interrupted; a deploy.sh re-run clears it"; echo
  fi
  health=$(lxc_query "$n" docker inspect -f '{{.State.Health.Status}}' technitium 2>/dev/null || echo missing)
  image=$(lxc_query "$n" docker inspect -f '{{.Config.Image}}' technitium 2>/dev/null || echo '?')
  printf '    %-26s ' "technitium container"; [[ "$health" == healthy ]] && good "healthy" || flag "$health"; printf '  %s\n' "${image##*/}"
  a=$(dq +short @"$(node_ip "$n")" debian.org A | head -1)
  printf '    %-26s ' "recursion (debian.org)"; [[ -n "$a" ]] && good "$a" || flag "no answer"; echo
  if [[ -n "$CFG_ZONE" ]]; then
    a=$(dq +short @"$(node_ip "$n")" "$CFG_NS1.$CFG_ZONE" A)
    printf '    %-26s ' "local zone ($CFG_NS1.$CFG_ZONE)"; [[ "$a" == "$(node_ip 1)" ]] && good "$a" || flag "${a:-no answer}"; echo
  fi
  if [[ -n "$CFG_LAN_DNS" ]]; then
    a=$(answers "$(node_ip "$n")" "no-such-host-$RANDOM.$CFG_LAN_DOMAIN" A)
    printf '    %-26s ' "LAN zone ($CFG_LAN_DOMAIN)"
    [[ "$a" == ok ]] && good "forwarded to $CFG_LAN_DNS" || flag "$a - forwarding loop or $CFG_LAN_DNS down (lan.sh)"; echo
  fi
  printf '    %-26s %s\n' "uptime" "$(lxc_query "$n" uptime -p 2>/dev/null || echo '?')"
done

# Zone replication: SOA serials as reported by each server's API (works for every zone type).
# A change made in the last few seconds may still be on its way (NOTIFY delay ~10s), so a
# mismatch is re-checked once before it counts as a problem.
declare -a zl=()
fetch_zone_lists() {
  local n
  zl=()
  for n in $(all_nodes); do
    zl[n]=""
    node_reachable "$n" 2>/dev/null || continue
    detect_tech_url "$n"
    tech_login "$n" 2>/dev/null || continue
    zl[n]=$(tech_api "$n" zones/list)
  done
  tech_logout
}
lists_complete() { local n; for n in $(all_nodes); do [[ -n "${zl[n]}" ]] || return 1; done; }
# zone_serials ZONE -> one serial per node, "-" where the zone is missing (or a copy's transfer fails)
zone_serials() {
  local n
  for n in $(all_nodes); do
    jq -r --arg z "$1" --argjson p "$( (( n == 1 )) && echo true || echo false)" \
      '[.zones[] | select(.name == $z and ($p or (.syncFailed | not))) | .soaSerial][0] // "-"' <<<"${zl[n]}"
  done | paste -sd' '
}
in_sync() { local s1 s; read -r s1 _ <<<"$1"; [[ "$s1" != - ]] || return 1; for s in $1; do [[ "$s" == "$s1" ]] || return 1; done; }
mapfile -t zones < <(managed_zones)
if (( ${#zones[@]} )); then
  fetch_zone_lists
  if lists_complete; then
    for z in "${zones[@]}"; do
      in_sync "$(zone_serials "$z")" || { sleep 12; fetch_zone_lists; break; }
    done
  fi
  for z in "${zones[@]}"; do
    printf '\n  %-28s ' "zone $z"
    if ! lists_complete; then flag "unknown (node unreachable or API login failed)"; continue; fi
    serials=$(zone_serials "$z")
    if in_sync "$serials"; then good "serial ${serials%% *} on $(all_word)"
    else
      flag "$(paste -d= <(for n in $(all_nodes); do node_var "$n" NS; done) <(tr ' ' '\n' <<<"$serials") | paste -sd' ') (out of sync; - = missing/failing)"
    fi
  done
fi

# Configuration drift is reported, not counted as a problem: DNS keeps working either way.
printf '\n  %-28s ' "configuration drift"
logged_in_all() {
  local n
  for n in $(all_nodes); do
    node_reachable "$n" && { detect_tech_url "$n"; tech_login "$n"; } 2>/dev/null || return 1
  done
}
if logged_in_all; then
  drift_report; tech_logout
  if (( ${#DRIFT_LINES[@]} )); then
    printf '%s%s difference(s) - details: backup.sh check%s' "$C_YELLOW" "${#DRIFT_LINES[@]}" "$C_RESET"
  else
    good "none"
  fi
else
  printf 'not checked (a node is unreachable or the API login failed)'
fi
echo; echo
(( problems == 0 )) && ok "All healthy" || { err "$problems problem(s) found"; exit 1; }
