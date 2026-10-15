# shellcheck shell=bash
# Technitium DNS: compose deployment + configuration through its HTTP API.
# All API calls run inside the LXC against 127.0.0.1:5380 (via lxc_query), so the web
# service never has to be reachable from this host for deployment to work.

declare -a TOKENS=() TECH_URL=()

# API base URL per node: HTTPS once the web UI has TLS enabled (HTTP then only redirects).
tech_url() { echo "${TECH_URL[$1]:-http://127.0.0.1:5380}"; }
detect_tech_url() {
  if lxc_query "$1" curl -sk -m 3 -o /dev/null https://127.0.0.1:53443/ 2>/dev/null; then
    TECH_URL[$1]=https://127.0.0.1:53443
  else
    TECH_URL[$1]=http://127.0.0.1:5380
  fi
}

tech_fqdn() { echo "$(node_var "$1" NS)${CFG_ZONE:+.$CFG_ZONE}"; }
node_ip()   { local v; v=$(node_var "$1" IP); echo "${v%/*}"; }

render_compose() {
  local n=$1 d=$CFG_SERVICE_DIR
  cat <<EOF
# Managed by proxmox-dns-ha-autodeploy. Update the image tag with update.sh (rolling, one node at a time).
name: technitium
services:
  technitium:
    image: docker.io/technitium/dns-server:$CFG_IMAGE_TAG
    container_name: technitium
    hostname: $(node_var "$n" NS)
    network_mode: host          # serves on the keepalived VIP as soon as it is added
    restart: unless-stopped
    env_file: .env
    volumes:
      - $d/data/config:/etc/dns
      - $d/data/logs:/var/log/technitium/dns
    healthcheck:
      test: ["CMD-SHELL", "curl -fsSkL http://127.0.0.1:5380/api/dnsClient/healthCheck | grep -q '\"status\":\"ok\"'"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 20s
    stop_grace_period: 30s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF
}

# render_env N [with_password]
render_env() {
  local n=$1 with_pw=${2:-no}
  cat <<EOF
# Managed by proxmox-dns-ha-autodeploy.
TZ=$CFG_TZ
DNS_SERVER_DOMAIN=$(tech_fqdn "$n")
DNS_SERVER_WEB_SERVICE_HTTP_PORT=5380
DNS_SERVER_LOG_FOLDER_PATH=/var/log/technitium/dns
DNS_SERVER_LOG_USING_LOCAL_TIME=true
EOF
  if [[ "$with_pw" == yes ]]; then
    echo "# First start only - removed automatically once the admin login is verified."
    echo "DNS_SERVER_ADMIN_PASSWORD=$ADMIN_PASSWORD"
  fi
}

# push_rendered N DEST PERMS RENDER_FN [ARGS...] — render locally into a private temp file, push it.
push_rendered() {
  local n=$1 dst=$2 perms=$3 tmp; shift 3
  tmp=$(mktemp "$STATE_DIR/render.XXXXXX")
  "$@" >"$tmp"
  lxc_push "$n" "$tmp" "$dst" "$perms"
  rm -f "$tmp"
}

wait_for_api() {
  local n=$1 i
  for (( i = 0; i < 60; i++ )); do
    lxc_query "$n" curl -fsS -m 3 -o /dev/null http://127.0.0.1:5380/ 2>/dev/null && return 0
    sleep 2
  done
  die "Technitium web service on $(node_var "$n" HOST) did not come up within 120s"
}

# Log in; the password travels over stdin, never on a command line.
tech_login() {
  local n=$1 resp
  resp=$(printf 'user=admin&pass=%s' "$(jq -rn --arg p "$ADMIN_PASSWORD" '$p|@uri')" \
    | lxc_query "$n" curl -sSk -m 30 -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-binary @- "$(tech_url "$n")/api/user/login") || die "Login request failed on $(node_var "$n" HOST)"
  [[ "$(jq -r .status <<<"$resp")" == ok ]] || return 1
  TOKENS[$n]=$(jq -r .token <<<"$resp")
}

# tech_api N ENDPOINT [key=value ...] — POST, prints the .response object, dies on error.
tech_api() {
  local n=$1 ep=$2 kv resp; shift 2
  local -a args=()
  for kv in "$@"; do args+=(--data-urlencode "$kv"); done
  resp=$(lxc_query "$n" curl -sSk -m 120 -X POST -H "Authorization: Bearer ${TOKENS[$n]}" \
    "${args[@]}" "$(tech_url "$n")/api/$ep") || die "API call $ep failed on $(node_var "$n" HOST)"
  if [[ "$(jq -r .status <<<"$resp" 2>/dev/null)" != ok ]]; then
    die "API $ep on $(node_var "$n" HOST): $(jq -r '.errorMessage // .status // .' <<<"$resp" 2>/dev/null || echo "$resp")"
  fi
  jq -c '.response // {}' <<<"$resp"
}

zone_exists() { tech_api "$1" zones/list | jq -e --arg z "$2" '.zones[] | select(.name == $z)' >/dev/null; }

# ------------------------------------------------------------ deployment ----
deploy_technitium() {
  local n=$1 d=$CFG_SERVICE_DIR host first_start=no
  host=$(node_var "$n" HOST)
  info "Deploying Technitium on $host ($(tech_fqdn "$n"))"
  lxc_exec "$n" install -d -m 755 "$d" "$d/data" "$d/data/config" "$d/data/logs"

  # A first start is one where Technitium has not created its user database yet.
  lxc_query "$n" test -e "$d/data/config/auth.config" || first_start=yes

  push_rendered "$n" "$d/compose.yaml" 0644 render_compose "$n"
  push_rendered "$n" "$d/.env" 0600 render_env "$n" "$first_start"
  lxc_exec "$n" docker compose --project-directory "$d" pull -q
  lxc_exec "$n" docker compose --project-directory "$d" up -d --quiet-pull
  wait_for_api "$n"
  detect_tech_url "$n"
  tech_login "$n" || die "Admin login failed on $host - if it was deployed before with another password, see reset-admin.sh"
  ok "$host: Technitium is up and the admin login works"

  if [[ "$first_start" == yes ]]; then
    lxc_query "$n" test -e "$d/data/config/auth.config" \
      || warn "$host: expected $d/data/config/auth.config after first start - re-runs may re-inject the password"
    push_rendered "$n" "$d/.env" 0600 render_env "$n" no
    lxc_exec "$n" docker compose --project-directory "$d" up -d   # recreate without the password
    wait_for_api "$n"
    detect_tech_url "$n"
    tech_login "$n" || die "Admin login failed on $host after removing the bootstrap password"
    ok "$host: bootstrap password removed from .env and the container environment"
  fi
}

forwarders_list() {
  local ip out=""
  for ip in $CFG_UPSTREAM_IPS; do out+="$CFG_UPSTREAM_DOH_URL ($ip),"; done
  echo "${out%,}"
}

configure_settings() {
  local n=$1
  local -a s=(
    "dnsServerDomain=$(tech_fqdn "$n")"
    "recursion=AllowOnlyForPrivateNetworks"
    "dnssecValidation=true"
    "serveStale=true"
    "forwarders=$(forwarders_list)"
    "forwarderProtocol=Https"
    "useSoaSerialDateScheme=true"   # new zones get YYYYMMDDnn serials
  )
  if [[ "$CFG_BLOCKLISTS" == yes ]]; then
    s+=("enableBlocking=true" "blockListUrls=${CFG_BLOCKLIST_URLS// /,}" "blockListUpdateIntervalHours=24")
  else
    s+=("enableBlocking=false" "blockListUrls=false")
  fi
  if [[ "$CFG_WEB_HTTPS" == yes ]]; then
    s+=("webServiceEnableTls=true" "webServiceTlsPort=53443" "webServiceUseSelfSignedTlsCertificate=true"
        "webServiceHttpToTlsRedirect=true")
  fi
  tech_api "$n" settings/set "${s[@]}" >/dev/null
  if [[ "$CFG_WEB_HTTPS" == yes && "$(tech_url "$n")" != https* ]]; then
    # TLS was just switched on; the web service restarts on 53443 and HTTP starts redirecting.
    local i
    for (( i = 0; i < 30; i++ )); do
      detect_tech_url "$n"; [[ "$(tech_url "$n")" == https* ]] && break; sleep 2
    done
    [[ "$(tech_url "$n")" == https* ]] || die "$(node_var "$n" HOST): HTTPS web service did not come up on 53443"
    tech_login "$n" || die "$(node_var "$n" HOST): login over HTTPS failed"
  fi
  ok "$(node_var "$n" HOST): DoH forwarders, private-only recursion, DNSSEC validation, serve-stale$( \
    [[ $CFG_BLOCKLISTS == yes ]] && echo ', blocklists')$([[ $CFG_WEB_HTTPS == yes ]] && echo ', HTTPS UI')"
}

# Zone transfers and NOTIFY from ns1 go to ns2's address only.
lock_transfers() {
  tech_api 1 zones/options/set "zone=$1" "zoneTransfer=UseSpecifiedNetworkACL" \
    "zoneTransferNetworkACL=$(node_ip 2)" "notify=SpecifiedNameServers" "notifyNameServers=$(node_ip 2)" >/dev/null
}

configure_zones() {
  [[ -n "$CFG_ZONE" ]] && configure_main_zone
  [[ -z "${CFG_EXTRA_ZONES:-}" ]] || {
    local z; for z in $CFG_EXTRA_ZONES; do ensure_forwarder_zone "$z"; done
  }
  if [[ -z "$(managed_zones)" ]]; then
    info "No local zone requested - forwarding-only resolvers"; return 0
  fi
  wait_for_zone_sync
}

configure_main_zone() {
  local z=$CFG_ZONE rz="" ptr=false sec_type=Secondary
  [[ "$CFG_PTR_ZONE" == yes ]] && { rz=$(reverse_zone_for "$CFG_IP1"); ptr=true; }

  # --- ns1: authoritative copy ---
  if ! zone_exists 1 "$z"; then
    if [[ "$CFG_ZONE_TYPE" == forwarder ]]; then
      tech_api 1 zones/create "zone=$z" type=Forwarder forwarder=this-server >/dev/null
    else
      tech_api 1 zones/create "zone=$z" type=Primary >/dev/null
    fi
    ok "$CFG_NS1: created $CFG_ZONE_TYPE zone $z"
  fi
  if [[ -n "$rz" ]] && ! zone_exists 1 "$rz"; then
    tech_api 1 zones/create "zone=$rz" type=Primary >/dev/null
    ok "$CFG_NS1: created reverse zone $rz"
  fi

  ensure_a "$z" "$CFG_NS1.$z" "$(node_ip 1)" "$ptr"
  ensure_a "$z" "$CFG_NS2.$z" "$(node_ip 2)" "$ptr"
  [[ -n "$CFG_VIP_RECORD" ]] && ensure_a "$z" "$CFG_VIP_RECORD.$z" "$CFG_VIP" "$ptr"
  local zz
  for zz in "$z" $rz; do
    [[ "$zz" == "$z" && "$CFG_ZONE_TYPE" == forwarder ]] && continue   # forwarder zones carry no NS set
    ensure_ns "$zz"
  done
  for zz in "$z" $rz; do ensure_serial_date_scheme "$zz"; lock_transfers "$zz"; done
  ok "$CFG_NS1: records verified; zone transfer + NOTIFY restricted to $CFG_NS2 ($(node_ip 2))"

  # --- ns2: secondary copies pulled from ns1 ---
  [[ "$CFG_ZONE_TYPE" == forwarder ]] && sec_type=SecondaryForwarder
  if ! zone_exists 2 "$z"; then
    tech_api 2 zones/create "zone=$z" "type=$sec_type" "primaryNameServerAddresses=$(node_ip 1)" zoneTransferProtocol=Tcp >/dev/null
    ok "$CFG_NS2: created $sec_type zone $z (primary $(node_ip 1))"
  fi
  if [[ -n "$rz" ]] && ! zone_exists 2 "$rz"; then
    tech_api 2 zones/create "zone=$rz" type=Secondary "primaryNameServerAddresses=$(node_ip 1)" zoneTransferProtocol=Tcp >/dev/null
    ok "$CFG_NS2: created Secondary zone $rz"
  fi
  for zz in "$z" $rz; do tech_api 2 zones/resync "zone=$zz" >/dev/null || true; done
}

# ----------------------------------------------------- additional zones ----
# Extra Conditional Forwarder zones (CFG_EXTRA_ZONES, helpers/zones.sh): records added on ns1
# are answered locally, names not in the zone go to the upstream resolvers like any other
# query. ns2 holds a SecondaryForwarder copy pulled from ns1 by zone transfer.

# zone_info N ZONE — the zones/list entry for ZONE on node N (empty when absent)
zone_info() { tech_api "$1" zones/list | jq -c --arg z "$2" '.zones[] | select(.name == $z)'; }
zone_type() { zone_info "$1" "$2" | jq -r '.type // empty'; }

# Every zone this deployment manages: main zone, reverse zone, extra zones.
managed_zones() {
  [[ -n "$CFG_ZONE" ]] && echo "$CFG_ZONE"
  [[ -n "$CFG_ZONE" && "$CFG_PTR_ZONE" == yes ]] && reverse_zone_for "$CFG_IP1"
  local z; for z in ${CFG_EXTRA_ZONES:-}; do echo "$z"; done
}

# ensure_forwarder_zone ZONE — idempotent. An existing Forwarder zone on ns1 (e.g. created in
# the web UI) is adopted as is; a zone of any other type is never touched.
ensure_forwarder_zone() {
  local z=$1 t
  t=$(zone_type 1 "$z")
  case "$t" in
    "")        tech_api 1 zones/create "zone=$z" type=Forwarder forwarder=this-server >/dev/null
               ok "$CFG_NS1: created Conditional Forwarder zone $z" ;;
    Forwarder) ;;
    *)         die "$CFG_NS1 already has $z as a $t zone - only Forwarder zones are managed here" ;;
  esac
  ensure_serial_date_scheme "$z"
  lock_transfers "$z"
  t=$(zone_type 2 "$z")
  case "$t" in
    "")                 tech_api 2 zones/create "zone=$z" type=SecondaryForwarder \
                          "primaryNameServerAddresses=$(node_ip 1)" zoneTransferProtocol=Tcp >/dev/null
                        ok "$CFG_NS2: created SecondaryForwarder zone $z (primary $(node_ip 1))" ;;
    SecondaryForwarder) ;;
    *)                  die "$CFG_NS2 already has $z as a $t zone - delete it there first" ;;
  esac
  tech_api 2 zones/resync "zone=$z" >/dev/null || true
}

# Records are only written when the authoritative answer on ns1 differs, so re-runs do not
# bump zone serials or briefly shrink the NS set.
ensure_a() {
  local z=$1 name=$2 ip=$3 ptr=$4 cur ptr_ok=yes
  cur=$(dq +short +norecurse @"$(node_ip 1)" "$name" A)
  [[ "$ptr" == true && "$(dq +short +norecurse @"$(node_ip 1)" -x "$ip")" != "$name." ]] && ptr_ok=no
  [[ "$cur" == "$ip" && "$ptr_ok" == yes ]] && return 0
  tech_api 1 zones/records/add "zone=$z" "domain=$name" type=A "ipAddress=$ip" overwrite=true "ptr=$ptr" >/dev/null
  ok "$CFG_NS1: $name A $ip$([[ "$ptr" == true ]] && echo ' (+PTR)')"
}

ensure_ns() {
  local zz=$1 want cur
  want=$(printf '%s\n' "$CFG_NS1.$CFG_ZONE." "$CFG_NS2.$CFG_ZONE." | sort)
  cur=$(dq +short +norecurse @"$(node_ip 1)" "$zz" NS | sort)
  [[ "$cur" == "$want" ]] && return 0
  # overwrite resets the NS set to ns1, then ns2 is added
  tech_api 1 zones/records/add "zone=$zz" "domain=$zz" type=NS "nameServer=$CFG_NS1.$CFG_ZONE" overwrite=true >/dev/null
  tech_api 1 zones/records/add "zone=$zz" "domain=$zz" type=NS "nameServer=$CFG_NS2.$CFG_ZONE" >/dev/null
  ok "$CFG_NS1: $zz NS = $CFG_NS1, $CFG_NS2"
}

# ensure_serial_date_scheme ZONE — switch ns1's copy of ZONE to YYYYMMDDnn SOA serials (the
# usual convention; a zone later moved to or from another server keeps transferring). The
# serial only ever increases, so ns2 follows by the normal NOTIFY + transfer. No-op if set.
ensure_serial_date_scheme() {
  local z=$1 r
  r=$(tech_api 1 zones/records/get "zone=$z" "domain=$z" | jq -c '.records[] | select(.type == "SOA") | .rData')
  [[ -n "$r" ]] || die "$CFG_NS1: no SOA record in $z"
  [[ "$(jq -r .useSerialDateScheme <<<"$r")" == true ]] && return 0
  tech_api 1 zones/records/update "zone=$z" "domain=$z" type=SOA \
    "primaryNameServer=$(jq -r .primaryNameServer <<<"$r")" "responsiblePerson=$(jq -r .responsiblePerson <<<"$r")" \
    "serial=$(jq -r .serial <<<"$r")" "refresh=$(jq -r .refresh <<<"$r")" "retry=$(jq -r .retry <<<"$r")" \
    "expire=$(jq -r .expire <<<"$r")" "minimum=$(jq -r .minimum <<<"$r")" useSerialDateScheme=true >/dev/null
  ok "$CFG_NS1: $z uses date-based SOA serials (YYYYMMDDnn)"
}

soa_serial() { dq +short +norecurse @"$1" "$2" SOA | awk '{print $3}'; }

# wait_for_zone_sync [ZONE...] — wait until ns2 holds the same version of every zone as ns1
# (equal SOA serials from the API, which also covers forwarder zones, and no failed transfer).
# Default: all managed zones.
wait_for_zone_sync() {
  local i zz s1 s2 l1 l2 pending
  local -a zones=("$@")
  (( ${#zones[@]} )) || mapfile -t zones < <(managed_zones)
  (( ${#zones[@]} )) || return 0
  for (( i = 0; i < 30; i++ )); do
    pending=""
    l1=$(tech_api 1 zones/list); l2=$(tech_api 2 zones/list)
    for zz in "${zones[@]}"; do
      s1=$(jq -r --arg z "$zz" '.zones[] | select(.name == $z) | .soaSerial // empty' <<<"$l1")
      s2=$(jq -r --arg z "$zz" '.zones[] | select(.name == $z and (.syncFailed | not)) | .soaSerial // empty' <<<"$l2")
      [[ -n "$s1" && "$s1" == "$s2" ]] || pending+=" $zz(${s1:-?}/${s2:-?})"
    done
    if [[ -z "$pending" ]]; then
      ok "$CFG_NS2 is in sync with $CFG_NS1 (serials: $(for zz in "${zones[@]}"; do
        printf '%s=%s ' "$zz" "$(jq -r --arg z "$zz" '.zones[] | select(.name == $z) | .soaSerial' <<<"$l2")"; done))"
      return 0
    fi
    (( i % 5 == 4 )) && for zz in "${zones[@]}"; do tech_api 2 zones/resync "zone=$zz" >/dev/null || true; done
    sleep 2
  done
  die "$CFG_NS2 not in sync with $CFG_NS1 after 60s:$pending"
}

tech_logout() { local n; for n in 1 2; do [[ -n "${TOKENS[$n]:-}" ]] && tech_api "$n" user/logout >/dev/null || true; done; }

# ----------------------------------------------------------- verification ---
VERIFY_FAIL=0
vcheck() {  # vcheck "description" expected actual
  if [[ "$3" == *"$2"* && -n "$2" ]]; then
    printf '  %sPASS%s  %-52s %s\n' "$C_GREEN" "$C_RESET" "$1" "$3"
  else
    printf '  %sFAIL%s  %-52s got: %s (expected %s)\n' "$C_RED" "$C_RESET" "$1" "${3:-<nothing>}" "$2"
    VERIFY_FAIL=$((VERIFY_FAIL+1))
  fi
}

dq() { dig +time=3 +tries=2 "$@" 2>/dev/null || true; }
rcode_of() { dq @"$1" "$2" A | grep -o 'status: [A-Z]*' | cut -d' ' -f2; }   # rcode_of SERVER NAME

verify_dns() {
  local n ip z=$CFG_ZONE
  section "DNS verification (queried from this host)"
  VERIFY_FAIL=0
  for n in 1 2; do
    ip=$(node_ip "$n")
    printf '  %s%s (%s)%s\n' "$C_BOLD" "$(node_var "$n" NS)" "$ip" "$C_RESET"
    vcheck "recursion via DoH: debian.org A" "NOERROR" "$(dq @"$ip" debian.org A | grep -o 'status: [A-Z]*' | cut -d' ' -f2)"
    vcheck "DNSSEC validated: isc.org (ad flag)" " ad" "$(dq +dnssec @"$ip" isc.org A | grep -o 'flags:[a-z ]*;' | head -1)"
    vcheck "DNSSEC bogus rejected: dnssec-failed.org" "SERVFAIL" "$(dq @"$ip" dnssec-failed.org A | grep -o 'status: [A-Z]*' | cut -d' ' -f2)"
    if [[ -n "$z" ]]; then
      vcheck "local: $CFG_NS1.$z" "$(node_ip 1)" "$(dq +short @"$ip" "$CFG_NS1.$z" A)"
      vcheck "local: $CFG_NS2.$z" "$(node_ip 2)" "$(dq +short @"$ip" "$CFG_NS2.$z" A)"
      [[ -n "$CFG_VIP_RECORD" ]] && vcheck "local: $CFG_VIP_RECORD.$z" "$CFG_VIP" "$(dq +short @"$ip" "$CFG_VIP_RECORD.$z" A)"
      if [[ "$CFG_ZONE_TYPE" == primary ]]; then
        vcheck "missing host in zone -> NXDOMAIN" "NXDOMAIN" "$(dq @"$ip" "no-such-host-$RANDOM.$z" A | grep -o 'status: [A-Z]*' | cut -d' ' -f2)"
      else
        vcheck "not in zone -> forwarded: www.$z = upstream" \
          "$(dq +short @"${CFG_UPSTREAM_IPS%% *}" "www.$z" A | sort | tr '\n' ' ')" \
          "$(dq +short @"$ip" "www.$z" A | sort | tr '\n' ' ')"
      fi
      [[ "$CFG_PTR_ZONE" == yes ]] && vcheck "PTR: $(node_ip 1)" "$CFG_NS1.$z." "$(dq +short @"$ip" -x "$(node_ip 1)")"
    fi
    local xz probe
    for xz in ${CFG_EXTRA_ZONES:-}; do
      probe="no-such-host-$RANDOM.$xz"
      vcheck "zone $xz: name not in zone -> forwarded" "$(rcode_of "${CFG_UPSTREAM_IPS%% *}" "$probe")" "$(rcode_of "$ip" "$probe")"
    done
  done
  if [[ -n "$z" && "$CFG_ZONE_TYPE" == primary ]]; then
    local s1 s2
    s1=$(dq +short @"$(node_ip 1)" "$z" SOA | awk '{print $3}'); s2=$(dq +short @"$(node_ip 2)" "$z" SOA | awk '{print $3}')
    vcheck "zone serial identical on both servers" "$s1" "$s2"
  fi
  (( VERIFY_FAIL == 0 )) || die "$VERIFY_FAIL DNS check(s) failed"
  ok "All DNS checks passed"
}
