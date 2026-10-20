#!/usr/bin/env bash
# Show the health of the Technitium HA pair: VIP holder, keepalived, container, DNS answers.
# Usage: status.sh [--config FILE]     Exit code: 0 healthy, 1 problems found.
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

problems=0
flag() { problems=$((problems+1)); printf '%s%s%s' "$C_RED" "$1" "$C_RESET"; }
good() { printf '%s%s%s' "$C_GREEN" "$1" "$C_RESET"; }

section "Technitium HA status - VIP $CFG_VIP"
holders=$(vip_holders 2>/dev/null || true)
printf '  %-28s ' "VIP holder"
case "$holders" in
  1|2) good "$(node_var "$holders" HOST)"; [[ "$holders" == 2 ]] && printf ' (failback to %s pending or %s unhealthy)' "$CFG_HOST1" "$CFG_HOST1" ;;
  "")  flag "NOBODY - DNS on the VIP is down" ;;
  *)   flag "BOTH NODES (split brain)" ;;
esac
echo
probe_name=localhost; [[ -n "$CFG_ZONE" ]] && probe_name="$CFG_NS1.$CFG_ZONE"
a=$(dq +short @"$CFG_VIP" "$probe_name" A | tail -1)
printf '  %-28s ' "DNS via VIP"; [[ -n "$a" ]] && good "answers ($a)" || flag "no answer"; echo

for n in 1 2; do
  printf '\n  %s%s%s (%s, VMID %s on %s)\n' "$C_BOLD" "$(node_var "$n" HOST)" "$C_RESET" "$(node_ip "$n")" \
    "$(node_var "$n" VMID)" "$(node_label "$n")"
  if ! node_reachable "$n"; then printf '    %-26s ' "SSH"; flag "unreachable"; echo; continue; fi
  ka=$(lxc_query "$n" systemctl is-active keepalived 2>/dev/null || true)
  st=$(ka_state "$n")
  printf '    %-26s ' "keepalived"; [[ "$ka" == active ]] && good "active, $st" || flag "$ka"; echo
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
fetch_zone_lists() {
  local n
  l1="" l2=""
  for n in 1 2; do
    node_reachable "$n" 2>/dev/null || continue
    detect_tech_url "$n"
    tech_login "$n" 2>/dev/null || continue
    printf -v "l$n" '%s' "$(tech_api "$n" zones/list)"
  done
  tech_logout
}
zone_serials() {  # zone_serials ZONE -> "s1 s2" (s2 empty if ns2 lacks the zone or its transfer fails)
  printf '%s %s' \
    "$(jq -r --arg z "$1" '.zones[] | select(.name == $z) | .soaSerial // empty' <<<"$l1")" \
    "$(jq -r --arg z "$1" '.zones[] | select(.name == $z and (.syncFailed | not)) | .soaSerial // empty' <<<"$l2")"
}
mapfile -t zones < <(managed_zones)
if (( ${#zones[@]} )); then
  fetch_zone_lists
  if [[ -n "$l1" && -n "$l2" ]]; then
    for z in "${zones[@]}"; do
      read -r s1 s2 < <(zone_serials "$z"; echo)
      [[ -n "$s1" && "$s1" == "${s2:-}" ]] || { sleep 12; fetch_zone_lists; break; }
    done
  fi
  for z in "${zones[@]}"; do
    printf '\n  %-28s ' "zone $z"
    if [[ -z "$l1" || -z "$l2" ]]; then flag "unknown (node unreachable or API login failed)"; continue; fi
    s1="" s2=""; read -r s1 s2 < <(zone_serials "$z"; echo)
    if [[ -n "$s1" && "$s1" == "$s2" ]]; then good "serial $s1 on both"
    else flag "${s1:-missing} vs ${s2:-missing/failing} (out of sync)"
    fi
  done
fi
echo; echo
(( problems == 0 )) && ok "All healthy" || { err "$problems problem(s) found"; exit 1; }
