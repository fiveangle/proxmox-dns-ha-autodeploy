#!/usr/bin/env bash
# Backups of both Technitium servers through Technitium's own backup API: each node's settings,
# users, zones, allowed/blocked lists, apps, DHCP scopes and stats - whatever is on it, changes
# made by hand included. Nothing is merged or reconciled: `check` reports what differs between
# the servers (or from what deploy.sh applied), and `restore` puts one node back exactly as it
# was in a backup, then lets deploy.sh's settings and zone copies take over again.
#
# Usage: backup.sh [--config FILE] [create] [--keep N]    back up both nodes (keep the newest N, default 14)
#        backup.sh [--config FILE] list
#        backup.sh [--config FILE] check                  drift report (exit 1 if anything differs)
#        backup.sh [--config FILE] restore SET 1|2 [--yes]
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

usage() {
  cat >&2 <<EOF
Usage: backup.sh [--config FILE] [create] [--keep N]
       backup.sh [--config FILE] list
       backup.sh [--config FILE] check
       backup.sh [--config FILE] restore SET 1|2 [--yes]
EOF
  exit 2
}
cmd=create; [[ -n "${1:-}" && "$1" != -* ]] && { cmd=$1; shift; }
YES=no KEEP=14; declare -a ARGS=()
while (( $# )); do
  case "$1" in
    --yes)  YES=yes; shift ;;
    --keep) KEEP=${2:-}; int_between "$KEEP" 1 1000 || die "--keep needs a number (1-1000)"; shift 2 ;;
    -*)     die "Unknown option: $1" ;;
    *)      ARGS+=("$1"); shift ;;
  esac
done

BACKUP_DIR="$STATE_DIR/backups"
# Everything except the block list cache (downloaded again) and query logs (large); a restore
# uses the same list. clusterConfig stays out: this deployment does not use Technitium clustering.
ITEMS="authConfig=true&webServiceSettings=true&dnsSettings=true&logSettings=true&zones=true"
ITEMS+="&allowedZones=true&blockedZones=true&apps=true&scopes=true&stats=true"

# zip_ok FILE — a readable zip archive; prints how many zone files it holds.
zip_ok() {
  python3 -I -c 'import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
if z.testzip() is not None: sys.exit(1)
print(sum(1 for n in z.namelist() if n.startswith("zones/")))' "$1" 2>/dev/null
}

# backup_node N DIR — DIR/<host>.zip; prints the node's manifest entry (JSON).
backup_node() {
  local n=$1 dir=$2 host file zones version
  host=$(node_var "$n" HOST); file="$dir/$host.zip"
  version=$(tech_api "$n" settings/get | jq -r .version)
  ( umask 077
    lxc_query "$n" curl -fsSk -m 600 -H "Authorization: Bearer ${TOKENS[$n]}" \
      "$(tech_url "$n")/api/settings/backup?$ITEMS" >"$file" ) \
    || { rm -f "$file"; die "$host: the backup download failed"; }
  zones=$(zip_ok "$file") || { rm -f "$file"; die "$host: the backup is not a valid zip archive"; }
  ok "$host: $(numfmt --to=iec --suffix=B "$(stat -c %s "$file")") backup, $zones zone file(s), Technitium $version" >&2
  jq -nc --argjson n "$n" --arg host "$host" --arg ns "$(node_var "$n" NS)" --arg ip "$(node_ip "$n")" \
    --arg vmid "$(node_var "$n" VMID)" --arg version "$version" --arg file "$host.zip" \
    --arg sha256 "$(sha256sum "$file" | cut -d' ' -f1)" --argjson zones "$zones" \
    '{node: $n, host: $host, ns: $ns, ip: $ip, vmid: $vmid, version: $version, file: $file, sha256: $sha256, zones: $zones}'
}

# new_set [SUFFIX] — create and print a new backup set directory
new_set() {
  local dir; dir="$BACKUP_DIR/$(date +%Y%m%d-%H%M%S)${1:+-$1}"
  install -d -m 700 "$BACKUP_DIR" "$dir"
  echo "$dir"
}

# write_manifest DIR ENTRY... — manifest.json plus a copy of the answers file
write_manifest() {
  local dir=$1; shift
  ( umask 077
    printf '%s\n' "$@" | jq -s --arg created "$(date -Is)" --arg vip "$CFG_VIP" \
      '{created: $created, tool: "proxmox-dns-ha-autodeploy", vip: $vip, nodes: .}' >"$dir/manifest.json"
    cp "$HELPER_CONFIG" "$dir/deploy.conf" )
}

print_drift() {
  local l
  if (( ${#DRIFT_LINES[@]} == 0 )); then
    ok "No drift: both servers match each other and what deploy.sh applied"
    return 0
  fi
  warn "${#DRIFT_LINES[@]} difference(s) this tool does not reconcile (fix them on the server named):"
  for l in "${DRIFT_LINES[@]}"; do printf '    %s\n' "$l"; done
  return 1
}

cmd_create() {
  (( ${#ARGS[@]} == 0 )) || usage
  local dir n s e
  local -a entries=()
  login_both
  dir=$(new_set)
  for n in 1 2; do e=$(backup_node "$n" "$dir") || exit 1; entries+=("$e"); done
  write_manifest "$dir" "${entries[@]}"
  ok "Backup set $(basename "$dir") saved in $BACKUP_DIR (root-only: it contains the login database)"
  # Keep the newest KEEP regular sets; pre-restore sets are never pruned.
  for s in $(ls -1 "$BACKUP_DIR" | grep -E '^[0-9]{8}-[0-9]{6}$' | sort -r | tail -n +$((KEEP + 1))); do
    rm -rf "${BACKUP_DIR:?}/$s"; info "Pruned old backup set $s"
  done
  drift_report
  print_drift || info "Details: backup.sh check"
}

cmd_list() {
  local d m
  [[ -d "$BACKUP_DIR" ]] && [[ -n "$(ls -A "$BACKUP_DIR")" ]] || { info "No backups in $BACKUP_DIR yet"; return 0; }
  printf '\n  %s%-28s %-8s %s%s\n' "$C_BOLD" Set Size Nodes "$C_RESET"
  for d in $(ls -1 "$BACKUP_DIR" | sort -r); do
    m="$BACKUP_DIR/$d/manifest.json"
    [[ -f "$m" ]] || continue
    printf '  %-28s %-8s %s\n' "$d" "$(numfmt --to=iec --suffix=B "$(cat "$BACKUP_DIR/$d"/* | wc -c)")" \
      "$(jq -r '[.nodes[] | "\(.host) (\(.ns), v\(.version), \(.zones) zones)"] | join(", ")' "$m")"
  done
  echo
}

cmd_check() {
  (( ${#ARGS[@]} == 0 )) || usage
  login_both
  drift_report
  print_drift || exit 1
}

cmd_restore() {
  (( ${#ARGS[@]} == 2 )) || usage
  local set=${ARGS[0]} n=${ARGS[1]} dir m entry file host cur ver pre e answer resp
  [[ "$n" == 1 || "$n" == 2 ]] || usage
  dir=$set; [[ -d "$dir" ]] || dir="$BACKUP_DIR/$set"
  m="$dir/manifest.json"
  [[ -f "$m" ]] || die "No backup set $set (see: backup.sh list)"
  host=$(node_var "$n" HOST)
  entry=$(jq -c --argjson n "$n" '.nodes[] | select(.node == $n)' "$m")
  [[ -n "$entry" ]] || die "Set $set has no backup of node $n"
  # A backup carries its server's identity (name, certificate): it only goes back where it came from.
  [[ "$(jq -r .ns <<<"$entry")" == "$(node_var "$n" NS)" && "$(jq -r .ip <<<"$entry")" == "$(node_ip "$n")" ]] \
    || die "That backup is of $(jq -r '"\(.ns) (\(.ip))"' <<<"$entry"), not $(node_var "$n" NS) ($(node_ip "$n")) - restore it onto the node it came from"
  file="$dir/$(jq -r .file <<<"$entry")"
  [[ "$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1)" == "$(jq -r .sha256 <<<"$entry")" ]] \
    || die "$file is missing or damaged (checksum mismatch)"

  login_both
  ver=$(jq -r .version <<<"$entry"); cur=$(tech_api "$n" settings/get | jq -r .version)
  if [[ "$ver" != "$cur" && "$(printf '%s\n' "$ver" "$cur" | sort -V | tail -1)" == "$ver" ]]; then
    die "The backup is from Technitium $ver, $host runs $cur - upgrade first: update.sh $ver"
  fi
  if [[ "$YES" != yes ]]; then
    answer=""; NONINTERACTIVE=0
    warn "$host goes back to $(basename "$dir"): settings, users, zones, apps and DHCP scopes. Changes made on it"
    warn "since then are lost (its current state is backed up first). Technitium restarts there; the VIP"
    warn "moves to the other node meanwhile if $host holds it."
    ask_yn answer "Restore $host from $(basename "$dir")?" no
    [[ "$answer" == yes ]] || exit 0
  fi

  pre=$(new_set prerestore)
  e=$(backup_node "$n" "$pre") || exit 1
  write_manifest "$pre" "$e"
  info "Current state of $host saved as $(basename "$pre")"

  lxc_push "$n" "$file" /tmp/pdha-restore.zip 0600
  resp=$(lxc_query "$n" curl -sSk -m 600 -X POST -H "Authorization: Bearer ${TOKENS[$n]}" \
    -F "fileBackupZip=@/tmp/pdha-restore.zip;type=application/zip" \
    "$(tech_url "$n")/api/settings/restore?$ITEMS&deleteExistingFiles=true") || resp=""
  lxc_exec "$n" rm -f /tmp/pdha-restore.zip
  # Technitium restarts its web service after restoring settings, which can cut the reply short;
  # only an explicit error means the restore did not happen.
  case "$(jq -r .status <<<"$resp" 2>/dev/null)" in
    ok) ok "$host: backup restored" ;;
    error|invalid-token)
        die "$host: restore failed: $(jq -r '.errorMessage // .status' <<<"$resp") - nothing was restored" ;;
    *)  warn "$host: no reply to the restore (Technitium restarting) - checking the result below"
        info "To undo: backup.sh restore $(basename "$pre") $n" ;;
  esac

  # A clean restart loads everything restored, whatever Technitium reloads on its own.
  lxc_exec "$n" docker compose --project-directory "$CFG_SERVICE_DIR" restart >/dev/null 2>&1
  wait_for_api "$n"
  detect_tech_url "$n"
  tech_login "$n" || die "$host: the restored login database has a different admin password - run: reset-admin.sh $n"

  section "Back to the deployment's settings and zone copies"
  local lines; lines=$(managed_settings_changes "$n")
  [[ -z "$lines" ]] || { warn "Settings from the backup that deploy.sh manages, reset to deploy.conf's values:"; sed 's/^/    /' <<<"$lines"; }
  configure_settings "$n"
  configure_zones                  # recreates missing zone copies; ns2 re-fetches every zone from ns1
  ok "$host restored from $(basename "$dir")"
  drift_report
  print_drift || true
}

case "$cmd" in
  create)  cmd_create ;;
  list)    cmd_list ;;
  check)   cmd_check ;;
  restore) cmd_restore ;;
  -h|--help|help) usage ;;
  *) die "Unknown command: $cmd (create | list | check | restore)" ;;
esac
