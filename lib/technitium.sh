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
  record_managed_settings "$n" "${s[@]%%=*}"
  ok "$(node_var "$n" HOST): DoH forwarders, private-only recursion, DNSSEC validation, serve-stale$( \
    [[ $CFG_BLOCKLISTS == yes ]] && echo ', blocklists')$([[ $CFG_WEB_HTTPS == yes ]] && echo ', HTTPS UI')"
}

# ------------------------------------------------- settings ownership -------
# The settings configure_settings writes belong to deploy.sh: every run resets them to the
# values from deploy.conf. What it applied is recorded inside the LXC, so a later run (and
# backup.sh check) can report changes made since - in the web UI, by API or by a restore -
# before they are reset. All other settings are left alone.
MANAGED_SETTINGS_FILE=managed-settings.json

# record_managed_settings N KEY... — store the current values of KEYs (as settings/get reports them)
record_managed_settings() {
  local n=$1 json; shift
  json=$(tech_api "$n" settings/get | jq -c '. as $c | reduce $ARGS.positional[] as $k ({}; .[$k] = $c[$k])' --args "$@")
  push_rendered "$n" "$CFG_SERVICE_DIR/$MANAGED_SETTINGS_FILE" 0600 printf '%s\n' "$json"
}

# managed_settings_changes N — one "key: applied -> now" line per managed setting changed on node
# N since deploy.sh last applied it. Silent when there is no record yet.
managed_settings_changes() {
  local n=$1 saved cur
  saved=$(lxc_query "$n" cat "$CFG_SERVICE_DIR/$MANAGED_SETTINGS_FILE" 2>/dev/null) || return 0
  [[ -n "$saved" ]] || return 0
  cur=$(tech_api "$n" settings/get)
  jq -rn --argjson s "$saved" --argjson c "$cur" \
    '$s | to_entries[] | select($c[.key] != .value) | "\(.key): \(.value | tojson) -> \($c[.key] | tojson)"'
}

# drift_report — what differs between the two servers, or from what deploy.sh applied, and is
# not reconciled automatically: Technitium versions, settings, managed settings changed by hand,
# zones on one server only. Both nodes must be logged in. Fills DRIFT_LINES with
# "<difference><TAB><how to fix it>"; prints nothing.
declare -a DRIFT_LINES=()
drift_add() { DRIFT_LINES+=("$1"$'\t'"$2"); }   # drift_add DIFFERENCE FIX
drift_report() {
  local s1 s2 v1 v2 l1 l2 n other line t managed
  DRIFT_LINES=()
  s1=$(tech_api 1 settings/get); s2=$(tech_api 2 settings/get)
  v1=$(jq -r .version <<<"$s1"); v2=$(jq -r .version <<<"$s2")
  [[ "$v1" == "$v2" ]] || drift_add "Technitium $CFG_NS1 $v1, $CFG_NS2 $v2" \
    "finish the rolling upgrade: update.sh $(printf '%s\n' "$v1" "$v2" | sort -V | tail -1)"
  # Settings that differ between the nodes (their own names, clocks and versions excepted).
  while IFS= read -r line; do
    [[ -n "$line" ]] && drift_add "$line" "make it the same on both servers (web UI > Settings), or clear it on the one that is wrong"
  done < <(
    jq -rn --argjson a "$s1" --argjson b "$s2" --arg n1 "$CFG_NS1" --arg n2 "$CFG_NS2" '
      ["dnsServerDomain", "uptimestamp", "blockListNextUpdatedOn", "version"] as $skip
      | [($a | keys[]), ($b | keys[])] | unique[] | . as $k
      | select(($skip | index($k)) == null and $a[$k] != $b[$k])
      | "setting \($k) differs: \($n1)=\($a[$k] | tojson | .[0:70]) \($n2)=\($b[$k] | tojson | .[0:70])"')
  for n in 1 2; do
    while IFS= read -r line; do
      [[ -n "$line" ]] && drift_add "$(node_var "$n" NS): changed outside deploy.sh: $line" \
        "to keep it, change it through deploy.sh's questions (deploy.conf); its next run resets it otherwise"
    done < <(managed_settings_changes "$n")
  done
  # Zones on one server only (not replicated, so answered only while that server holds the VIP).
  l1=$(tech_api 1 zones/list); l2=$(tech_api 2 zones/list)
  managed=$(managed_zones)
  for n in 1 2; do
    other=$(( 3 - n ))
    while IFS=$'\t' read -r line t; do
      [[ -n "$line" ]] || continue
      grep -qxF "$line" <<<"$managed" && continue
      drift_add "zone $line ($t) exists only on $(node_var "$n" NS): answered only while it holds the VIP" "$(
        case "$n:$t" in
          1:Primary|1:Forwarder) echo "zones.sh add $line (copies it to $CFG_NS2), or delete it on $CFG_NS1" ;;
          1:*)   echo "zones.sh copies only Primary/Forwarder zones: delete it on $CFG_NS1, or create the same zone on $CFG_NS2 by hand" ;;
          2:Primary|2:Forwarder) echo "edits belong on $CFG_NS1: export it on $CFG_NS2 (web UI > Zones), import it into a new $t zone on $CFG_NS1, delete it on $CFG_NS2, then zones.sh add $line" ;;
          2:*)   echo "probably a leftover copy: delete it on $CFG_NS2" ;;
        esac)"
    done < <(jq -r --argjson o "$([[ $other == 1 ]] && echo "$l1" || echo "$l2")" \
      '.zones[] | select(.internal | not) | .name as $z
       | select(([$o.zones[].name] | index($z)) == null) | "\($z)\t\(.type)"' \
      <<<"$([[ $n == 1 ]] && echo "$l1" || echo "$l2")")
  done
  return 0
}

# Zone transfers and NOTIFY from ns1 go to ns2's address only.
lock_transfers() {
  tech_api 1 zones/options/set "zone=$1" "zoneTransfer=UseSpecifiedNetworkACL" \
    "zoneTransferNetworkACL=$(node_ip 2)" "notify=SpecifiedNameServers" "notifyNameServers=$(node_ip 2)" >/dev/null
}

configure_zones() {
  local rz; rz=$(reverse_zone)
  [[ -n "$rz" ]] && ensure_reverse_zone       # first: the main zone's A records add PTRs to it
  [[ -n "$CFG_ZONE" ]] && configure_main_zone
  [[ -n "$rz" ]] && finish_reverse_zone
  [[ -z "${CFG_EXTRA_ZONES:-}" ]] || {
    local z; for z in $CFG_EXTRA_ZONES; do ensure_extra_zone "$z"; done
  }
  [[ -n "${CFG_LAN_DNS:-}" ]] && ensure_forwarder_zone "$CFG_LAN_DOMAIN" "$CFG_LAN_DNS"
  if [[ -z "$(managed_zones)" ]]; then
    info "No local zone requested - forwarding-only resolvers"; return 0
  fi
  wait_for_zone_sync
}

configure_main_zone() {
  local z=$CFG_ZONE ptr=false sec_type=Secondary
  [[ -n "$(reverse_zone)" ]] && ptr=true

  # --- ns1: authoritative copy ---
  if ! zone_exists 1 "$z"; then
    if [[ "$CFG_ZONE_TYPE" == forwarder ]]; then
      tech_api 1 zones/create "zone=$z" type=Forwarder forwarder=this-server >/dev/null
    else
      tech_api 1 zones/create "zone=$z" type=Primary >/dev/null
    fi
    ok "$CFG_NS1: created $CFG_ZONE_TYPE zone $z"
  fi

  ensure_a "$z" "$CFG_NS1.$z" "$(node_ip 1)" "$ptr"
  ensure_a "$z" "$CFG_NS2.$z" "$(node_ip 2)" "$ptr"
  [[ -n "$CFG_VIP_RECORD" ]] && ensure_a "$z" "$CFG_VIP_RECORD.$z" "$CFG_VIP" "$ptr"
  [[ "$CFG_ZONE_TYPE" == forwarder ]] || ensure_ns "$z"   # forwarder zones carry no NS set
  ensure_serial_date_scheme "$z"; lock_transfers "$z"
  ok "$CFG_NS1: records verified; zone transfer + NOTIFY restricted to $CFG_NS2 ($(node_ip 2))"

  # --- ns2: secondary copy pulled from ns1 ---
  [[ "$CFG_ZONE_TYPE" == forwarder ]] && sec_type=SecondaryForwarder
  ensure_ns2_copy "$z" "$sec_type"
}

# ---------------------------------------------------------- reverse zone ----
# The reverse zone of the LXC subnet exists when CFG_PTR_ZONE asks for the servers' PTR records
# or CFG_LAN_PTR sends reverse lookups to the router. With CFG_LAN_PTR it is a Conditional
# Forwarder zone: the servers' PTR records are answered locally, every other address goes to
# the router. Otherwise it is a Primary zone. Switching converts the zone in place (records kept).
reverse_zone() {
  if [[ ( -n "$CFG_ZONE" && "$CFG_PTR_ZONE" == yes ) || ( -n "${CFG_LAN_DNS:-}" && "${CFG_LAN_PTR:-no}" == yes ) ]]; then
    reverse_zone_for "$CFG_IP1"
  fi
}
reverse_zone_type() { [[ -n "${CFG_LAN_DNS:-}" && "${CFG_LAN_PTR:-no}" == yes ]] && echo Forwarder || echo Primary; }

# ensure_reverse_zone — ns1's copy exists with the right type (and forwarder).
ensure_reverse_zone() {
  local rz want t
  rz=$(reverse_zone); want=$(reverse_zone_type); t=$(zone_type 1 "$rz")
  if [[ -z "$t" ]]; then
    if [[ "$want" == Forwarder ]]; then
      tech_api 1 zones/create "zone=$rz" type=Forwarder protocol=Udp "forwarder=$CFG_LAN_DNS" dnssecValidation=false >/dev/null
    else
      tech_api 1 zones/create "zone=$rz" type=Primary >/dev/null
    fi
    ok "$CFG_NS1: created reverse zone $rz ($want)"
  elif [[ "$t" != "$want" ]]; then
    [[ "$t" == Primary || "$t" == Forwarder ]] || die "$CFG_NS1 already has $rz as a $t zone - delete it there first"
    tech_api 1 zones/convert "zone=$rz" "type=$want" >/dev/null
    ok "$CFG_NS1: converted reverse zone $rz from $t to $want (records kept)"
  fi
  [[ "$want" == Forwarder ]] && ensure_apex_fwd "$rz" "$CFG_LAN_DNS"
  return 0
}

# finish_reverse_zone — NS set (Primary only), serials, transfer lock and ns2's copy; runs after
# the main zone has added its PTR records.
finish_reverse_zone() {
  local rz type
  rz=$(reverse_zone); type=$(reverse_zone_type)
  [[ "$type" == Primary ]] && ensure_ns "$rz"
  ensure_serial_date_scheme "$rz"; lock_transfers "$rz"
  ensure_ns2_copy "$rz" "Secondary${type/Primary/}"
}

# ensure_ns2_copy ZONE TYPE — ns2 holds a TYPE (Secondary|SecondaryForwarder) copy of ZONE pulled
# from ns1. A copy of the other secondary type (the zone was converted on ns1) is replaced.
ensure_ns2_copy() {
  local z=$1 want=$2 t
  t=$(zone_type 2 "$z")
  if [[ -n "$t" && "$t" != "$want" ]]; then
    [[ "$t" == Secondary || "$t" == SecondaryForwarder ]] || die "$CFG_NS2 already has $z as a $t zone - delete it there first"
    tech_api 2 zones/delete "zone=$z" >/dev/null
    ok "$CFG_NS2: removed the $t copy of $z (replaced by a $want copy)"
    t=""
  fi
  if [[ -z "$t" ]]; then
    tech_api 2 zones/create "zone=$z" "type=$want" "primaryNameServerAddresses=$(node_ip 1)" zoneTransferProtocol=Tcp >/dev/null
    ok "$CFG_NS2: created $want zone $z (primary $(node_ip 1))"
  fi
  tech_api 2 zones/resync "zone=$z" >/dev/null || true
}

# ensure_apex_fwd ZONE IP — names not in ZONE are forwarded to IP over plain DNS, without
# DNSSEC validation (LAN names are unsigned). The FWD record is only rewritten when different.
ensure_apex_fwd() {
  local z=$1 ip=$2 cur
  cur=$(tech_api 1 zones/records/get "zone=$z" "domain=$z" \
    | jq -r '[.records[] | select(.type == "FWD") | "\(.rData.protocol) \(.rData.forwarder) \(.rData.dnssecValidation)"] | join(",")')
  [[ "$cur" == "Udp $ip false" ]] && return 0
  tech_api 1 zones/records/add "zone=$z" "domain=$z" type=FWD protocol=Udp "forwarder=$ip" \
    dnssecValidation=false overwrite=true >/dev/null
  ok "$CFG_NS1: $z forwards names not in the zone to $ip"
}

# ----------------------------------------------------- additional zones ----
# Extra zones (CFG_EXTRA_ZONES, helpers/zones.sh): new ones are Conditional Forwarder zones -
# records added on ns1 are answered locally, names not in the zone go to the upstream resolvers
# like any other query - with a SecondaryForwarder copy on ns2. A Primary zone already on ns1
# (e.g. made in the web UI) is adopted as is, with a Secondary copy on ns2: it answers NXDOMAIN
# for names it does not hold. Either way ns2 follows ns1 by zone transfer + NOTIFY.

# zone_info N ZONE — the zones/list entry for ZONE on node N (empty when absent)
zone_info() { tech_api "$1" zones/list | jq -c --arg z "$2" '.zones[] | select(.name == $z)'; }
zone_type() { zone_info "$1" "$2" | jq -r '.type // empty'; }

# Every zone this deployment manages: main zone, reverse zone, extra zones, LAN zone.
managed_zones() {
  [[ -n "$CFG_ZONE" ]] && echo "$CFG_ZONE"
  reverse_zone
  local z; for z in ${CFG_EXTRA_ZONES:-}; do echo "$z"; done
  [[ -n "${CFG_LAN_DNS:-}" ]] && echo "$CFG_LAN_DOMAIN"
  return 0
}

# ensure_forwarder_zone ZONE [IP] — idempotent. Names not in the zone go upstream like any other
# query, or with IP to that server (the LAN zone: the router answers for its DHCP clients).
# An existing Forwarder zone on ns1 (e.g. created in the web UI) is adopted; a zone of any
# other type is never touched.
ensure_forwarder_zone() {
  local z=$1 ip=${2:-} t
  local -a fwd=(forwarder=this-server)
  [[ -n "$ip" ]] && fwd=(protocol=Udp "forwarder=$ip" dnssecValidation=false)
  t=$(zone_type 1 "$z")
  case "$t" in
    "")        tech_api 1 zones/create "zone=$z" type=Forwarder "${fwd[@]}" >/dev/null
               ok "$CFG_NS1: created Conditional Forwarder zone $z${ip:+ -> $ip}" ;;
    Forwarder) ;;
    *)         die "$CFG_NS1 already has $z as a $t zone - only Primary and Forwarder zones are managed here" ;;
  esac
  [[ -n "$ip" ]] && ensure_apex_fwd "$z" "$ip"
  ensure_serial_date_scheme "$z"
  lock_transfers "$z"
  ensure_ns2_copy "$z" SecondaryForwarder
}

# ensure_extra_zone ZONE — idempotent: adopts a Primary zone on ns1, otherwise a Forwarder zone.
# Records of an adopted zone are never changed.
ensure_extra_zone() {
  local z=$1
  if [[ "$(zone_type 1 "$z")" != Primary ]]; then ensure_forwarder_zone "$z"; return; fi
  ensure_serial_date_scheme "$z"
  lock_transfers "$z"
  ensure_ns2_copy "$z" Secondary
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

# answers SERVER DIG-ARGS... — "ok" when SERVER gives a definite answer (NOERROR or NXDOMAIN),
# otherwise its rcode or "timeout". For a forwarded LAN name, SERVFAIL or a timeout usually
# means a loop: the router sends names it does not know back to these servers.
answers() {
  local rc; rc=$(dq @"$1" "${@:2}" | grep -o 'status: [A-Z]*' | cut -d' ' -f2)
  [[ "$rc" == NOERROR || "$rc" == NXDOMAIN ]] && echo ok || echo "${rc:-timeout}"
}

# lan_sample_name — the router's own name under CFG_LAN_DOMAIN, read from its PTR record: the
# one name every DHCP DNS server publishes. Empty when it does not answer with such a name.
lan_sample_name() {
  local n; n=$(dq +short @"$CFG_LAN_DNS" -x "$CFG_LAN_DNS" | head -1)
  [[ "${n,,}" == *".${CFG_LAN_DOMAIN,,}." ]] && echo "${n%.}"
  return 0
}

# verify_lan IP — LAN zone checks against one server (vcheck lines). Sets LAN_LOOP when a
# forwarded name got no definite answer.
verify_lan() {
  local ip=$1 name=${LAN_NAME:-} r
  r=$(answers "$ip" "no-such-host-$RANDOM.$CFG_LAN_DOMAIN" A)
  [[ "$r" == ok ]] || LAN_LOOP=1
  vcheck "LAN: unknown name in $CFG_LAN_DOMAIN answered" ok "$r"
  [[ -n "$name" ]] && vcheck "LAN: $name (from $CFG_LAN_DNS)" "$CFG_LAN_DNS" "$(dq +short @"$ip" "$name" A)"
  if [[ "$CFG_LAN_PTR" == yes ]]; then
    # The subnet's network address: never a host, so the router has to answer NXDOMAIN.
    r=$(answers "$ip" -x "$(cidr_network "$CFG_IP1" | cut -d/ -f1)")
    [[ "$r" == ok ]] || LAN_LOOP=1
    vcheck "LAN reverse: unknown address answered" ok "$r"
    [[ -n "$name" ]] && vcheck "LAN reverse: $CFG_LAN_DNS" "$name." "$(dq +short @"$ip" -x "$CFG_LAN_DNS")"
  fi
  return 0
}

# lan_probe — sets LAN_NAME and explains when the router publishes no names under the domain.
lan_probe() {
  LAN_LOOP=0
  LAN_NAME=$(lan_sample_name)
  if [[ -n "$LAN_NAME" ]]; then
    info "$CFG_LAN_DNS publishes its own name $LAN_NAME; DHCP clients appear as <hostname>.$CFG_LAN_DOMAIN"
    info "if it registers them (some routers only register their own name)"
  else
    warn "$CFG_LAN_DNS does not answer a name in $CFG_LAN_DOMAIN for its own address - set its local"
    warn "domain to $CFG_LAN_DOMAIN; until then nothing resolves under it"
  fi
}

lan_loop_hint() {
  (( ${LAN_LOOP:-0} )) || return 0
  warn "Forwarded LAN lookups got no answer. If the router's upstream DNS is $CFG_VIP, it sends"
  warn "names it does not know back here: make it answer $CFG_LAN_DOMAIN itself (dnsmasq:"
  warn "local=/$CFG_LAN_DOMAIN/) or give it a different upstream."
}

verify_dns() {
  local n ip z=$CFG_ZONE
  section "DNS verification (queried from this host)"
  VERIFY_FAIL=0
  [[ -n "${CFG_LAN_DNS:-}" ]] && lan_probe
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
      [[ -n "$(reverse_zone)" ]] && vcheck "PTR: $(node_ip 1)" "$CFG_NS1.$z." "$(dq +short @"$ip" -x "$(node_ip 1)")"
    fi
    local xz probe
    for xz in ${CFG_EXTRA_ZONES:-}; do
      probe="no-such-host-$RANDOM.$xz"
      if [[ "$(zone_type 1 "$xz")" == Primary ]]; then
        vcheck "zone $xz: not in zone -> NXDOMAIN" NXDOMAIN "$(rcode_of "$ip" "$probe")"
      else
        vcheck "zone $xz: name not in zone -> forwarded" "$(rcode_of "${CFG_UPSTREAM_IPS%% *}" "$probe")" "$(rcode_of "$ip" "$probe")"
      fi
    done
    [[ -n "${CFG_LAN_DNS:-}" ]] && verify_lan "$ip"
  done
  [[ -n "${CFG_LAN_DNS:-}" ]] && lan_loop_hint
  if [[ -n "$z" && "$CFG_ZONE_TYPE" == primary ]]; then
    local s1 s2
    s1=$(dq +short @"$(node_ip 1)" "$z" SOA | awk '{print $3}'); s2=$(dq +short @"$(node_ip 2)" "$z" SOA | awk '{print $3}')
    vcheck "zone serial identical on both servers" "$s1" "$s2"
  fi
  (( VERIFY_FAIL == 0 )) || die "$VERIFY_FAIL DNS check(s) failed"
  ok "All DNS checks passed"
}
