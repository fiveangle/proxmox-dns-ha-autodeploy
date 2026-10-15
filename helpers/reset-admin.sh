#!/usr/bin/env bash
# Admin password recovery using Technitium's own mechanism: auth.config is renamed to
# resetadmin.config; on start Technitium loads it (keeping all users, groups, zone permissions
# and API tokens), resets only the admin user to password "admin" (re-enabled, 2FA off) and
# writes a fresh auth.config. The script then logs in and sets the new password immediately.
# NOTE: deleting auth.config instead is NOT safe in v15 - the server crashes on start because
# zone permissions live in that file.
# Usage: reset-admin.sh [--config FILE] [1|2|all] [--yes]     (default: all, BACKUP node first)
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

target=all YES=no
for a in "$@"; do case "$a" in 1|2|all) target=$a ;; --yes) YES=yes ;; *) die "Unknown argument: $a" ;; esac; done
D=$CFG_SERVICE_DIR

if [[ "$target" == all ]]; then
  holder=$(vip_holders); [[ "$holder" == 1 || "$holder" == 2 ]] || holder=1
  nodes=("$(( 3 - holder ))" "$holder")
else
  nodes=("$target")
fi
node_names=""; for n in "${nodes[@]}"; do node_names+="$(node_var "$n" HOST) "; done

NONINTERACTIVE=0
if [[ "$YES" != yes ]]; then
  answer=""
  ask_yn answer "Reset the admin password on ${node_names}(restarts Technitium there)?" no
  [[ "$answer" == yes ]] || exit 0
fi
prompt_admin_password        # offers the saved password, or a new / generated one

# change_password N OLD NEW — both passwords travel over stdin, never on a command line.
change_password() {
  local n=$1 resp
  resp=$(printf 'pass=%s&newPass=%s' "$(jq -rn --arg p "$2" '$p|@uri')" "$(jq -rn --arg p "$3" '$p|@uri')" \
    | lxc_query "$n" curl -sSk -m 30 -H "Authorization: Bearer ${TOKENS[$n]}" \
        -H 'Content-Type: application/x-www-form-urlencoded' --data-binary @- "$(tech_url "$n")/api/user/changePassword")
  [[ "$(jq -r .status <<<"$resp" 2>/dev/null)" == ok ]]
}

reset_node() {
  local n=$1 host ts cfg new_pw=$ADMIN_PASSWORD
  host=$(node_var "$n" HOST); ts=$(date +%Y%m%d-%H%M%S); cfg="$D/data/config"
  node_reachable "$n" || die "$host is not reachable over SSH"
  info "$host: resetting the admin password (other users, zones and settings are kept)"

  restore() {
    ADMIN_PASSWORD=$new_pw
    err "$host: $1 - restoring the original auth.config"
    lxc_exec "$n" docker compose --project-directory "$D" stop >/dev/null 2>&1 || true
    lxc_exec "$n" sh -c "rm -f '$cfg/resetadmin.config'; cp -a '$cfg/auth.config.bak-$ts' '$cfg/auth.config'"
    lxc_exec "$n" docker compose --project-directory "$D" up -d >/dev/null 2>&1 || true
    die "$host: reset failed; original user database restored"
  }

  lxc_exec "$n" docker compose --project-directory "$D" stop >/dev/null 2>&1
  lxc_exec "$n" sh -c "cp -a '$cfg/auth.config' '$cfg/auth.config.bak-$ts' && mv '$cfg/auth.config' '$cfg/resetadmin.config'"
  lxc_exec "$n" docker compose --project-directory "$D" up -d >/dev/null 2>&1
  ( wait_for_api "$n" ) || restore "Technitium did not start"
  detect_tech_url "$n"

  # The window in which admin/admin works lasts only until the next API call.
  ADMIN_PASSWORD=admin
  tech_login "$n" || restore "login with the reset password failed"
  change_password "$n" admin "$new_pw" || restore "setting the new password failed"
  ADMIN_PASSWORD=$new_pw
  tech_api "$n" user/logout >/dev/null || true

  tech_login "$n" || die "$host: login with the new password failed"
  tech_api "$n" user/logout >/dev/null || true
  lxc_query "$n" test ! -e "$cfg/resetadmin.config" || warn "$host: resetadmin.config still present"
  ok "$host: admin password reset and verified (previous user database kept as auth.config.bak-$ts)"
}

for n in "${nodes[@]}"; do
  reset_node "$n"
  if [[ "$n" != "${nodes[-1]}" ]]; then info "Waiting for $(node_var "$n" HOST) to rejoin keepalived"; sleep 5; fi
done
[[ -n "$VRRP_AUTH_PASS" ]] || ensure_vrrp_secret
save_credentials
if [[ "$target" != all ]]; then
  warn "Only $(node_var "$target" HOST) was reset; the saved password now matches it. Use 'all' to keep both nodes identical."
fi
