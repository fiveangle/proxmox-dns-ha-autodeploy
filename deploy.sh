#!/usr/bin/env bash
# Deploy two (or, with CFG_SECONDARIES, up to four) Debian 13 LXCs on Proxmox VE, each running
# Technitium DNS (docker compose) and keepalived, sharing one floating virtual IP.
#
# Usage: deploy.sh [--config FILE] [--dry-run] [--help]
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/node.sh
source "$SCRIPT_DIR/lib/node.sh"
# shellcheck source=lib/prompts.sh
source "$SCRIPT_DIR/lib/prompts.sh"
# shellcheck source=lib/preflight.sh
source "$SCRIPT_DIR/lib/preflight.sh"
# shellcheck source=lib/lxc.sh
source "$SCRIPT_DIR/lib/lxc.sh"
# shellcheck source=lib/docker.sh
source "$SCRIPT_DIR/lib/docker.sh"
# shellcheck source=lib/technitium.sh
source "$SCRIPT_DIR/lib/technitium.sh"
# shellcheck source=lib/keepalived.sh
source "$SCRIPT_DIR/lib/keepalived.sh"
# shellcheck source=lib/extras.sh
source "$SCRIPT_DIR/lib/extras.sh"
# shellcheck source=lib/finalize.sh
source "$SCRIPT_DIR/lib/finalize.sh"

trap on_error ERR

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

  --config FILE   Use saved answers (no questions). Default answers file:
                  $CONFIG_FILE_DEFAULT
                  Without --config, a deploy.conf in the current directory is
                  offered for use.
  --failover-test / --no-failover-test
                  Run (or skip) the live failover test at the end without asking.
  --dry-run       Ask questions and run pre-flight checks, then print every action
                  without changing anything.
  -h, --help      Show this help.
EOF
}

CONFIG_ARG=""
NONINTERACTIVE=0
FAILOVER_TEST=""
while (( $# )); do
  case "$1" in
    --config)  CONFIG_ARG=${2:-}; [[ -n "$CONFIG_ARG" ]] || die "--config needs a file"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --failover-test) FAILOVER_TEST=yes; shift ;;
    --no-failover-test) FAILOVER_TEST=no; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "Unknown option: $1" ;;
  esac
done

print_dry_run_plan() {
  local n secs
  secs=$(for n in $(secondary_nodes); do node_var "$n" NS; done | paste -sd, | sed 's/,/, /g')
  section "Planned actions (dry run - nothing was changed)"
  for n in $(all_nodes); do
    [[ "${RESUME[$n]}" == 1 ]] && { info "Node $n: reuse existing VMID $(node_var "$n" VMID)"; continue; }
    ensure_template "$n"
    pct_create_args "$n" "$CFG_SSH_KEY_FILE"
    node_run "$n" "${PCT_ARGS[@]}"
  done
  cat <<EOF

  Then, on each LXC:
    - apt full-upgrade; install keepalived, bind9-dnsutils, jq, curl${CFG_EXTRA_PACKAGES:+
    - extra packages: $CFG_EXTRA_PACKAGES}
    - install Docker CE + compose plugin from download.docker.com (trixie)
    - verify $(all_word) LXCs share one L2 segment (required for the VIP)
    - write $CFG_SERVICE_DIR/compose.yaml and .env; bind mount $CFG_SERVICE_DIR/data/config -> /etc/dns
    - docker compose up -d (technitium/dns-server:$CFG_IMAGE_TAG, network_mode: host)
    - configure Technitium via its API: DoH forwarders, recursion (private nets),
      DNSSEC validation, serve-stale${CFG_ZONE:+, zone $CFG_ZONE ($CFG_ZONE_TYPE) on $CFG_NS1 -> secondary on $secs}${CFG_EXTRA_ZONES:+
      extra zones (new: Conditional Forwarder; existing Primary kept) on $CFG_NS1 -> secondary on $secs: $CFG_EXTRA_ZONES}${CFG_LAN_DNS:+
      LAN zone $CFG_LAN_DOMAIN -> $CFG_LAN_DNS (plain DNS)}$([[ -n $CFG_LAN_DNS && $CFG_LAN_PTR == yes ]] && echo ", reverse zone $(reverse_zone) -> $CFG_LAN_DNS")
    - keepalived: VIP $CFG_VIP, vrid $CFG_VRID, unicast, health check every 1s,
      $(for n in $(all_nodes); do printf '%s priority %s / ' "$(node_var "$n" HOST)" "$(node_priority "$n")"; done | sed 's| / $||'), preempt_delay 60${RETIRED[*]:+
    - stop the LXC(s) of node(s) no longer in the deployment: $(for n in "${RETIRED[@]}"; do printf '%s ' "$(node_var "$n" HOST)"; done)}
    - switch LXC resolver to 127.0.0.1 (upstream as fallback)
  Optional: PTR zone=$CFG_PTR_ZONE, blocklists=$CFG_BLOCKLISTS, HTTPS UI=$CFG_WEB_HTTPS,
            PVE firewall=$CFG_FIREWALL, unattended-upgrades=$CFG_UNATTENDED
EOF
}

main() {
  preflight_host

  if [[ -z "$CONFIG_ARG" && -f "$PWD/deploy.conf" ]]; then
    local use_local=yes
    ask_yn use_local "Found $PWD/deploy.conf - use it (no questions)? (n = answer interactively)" yes
    [[ "$use_local" == yes ]] && CONFIG_ARG="$PWD/deploy.conf"
  fi

  if [[ -n "$CONFIG_ARG" ]]; then
    NONINTERACTIVE=1
    load_config "$CONFIG_ARG"
    ensure_nodes_ssh
    resolve_template              # always the newest Debian 13 template, whatever the file says
    validate_config
    print_summary
  else
    if [[ -f "$CONFIG_FILE_DEFAULT" ]]; then
      local reuse=yes
      ask_yn reuse "Saved answers found in $CONFIG_FILE_DEFAULT - use them as defaults?" yes
      [[ "$reuse" == yes ]] && load_config "$CONFIG_FILE_DEFAULT"
    fi
    local confirmed
    while true; do
      prompt_all
      print_summary
      confirmed=""   # ask_yn treats a pre-set value as the default
      ask_yn confirmed "Proceed with these settings? (n = edit answers again)" yes
      [[ "$confirmed" == yes ]] && break
    done
    save_config "$CONFIG_FILE_DEFAULT"
  fi

  if [[ "$DRY_RUN" == 1 ]]; then
    info "Dry run: admin password prompt skipped"
  else
    prompt_admin_password
  fi

  start_logging
  preflight_all
  if (( MANUAL_SETTINGS > 0 )) && [[ "$NONINTERACTIVE" != 1 && "$DRY_RUN" != 1 ]]; then
    local reset=""
    ask_yn reset "Reset the $MANUAL_SETTINGS setting(s) above to deploy.conf's values and continue?" no
    [[ "$reset" == yes ]] || die "Nothing was changed. deploy.sh owns those settings: change them through its questions"
  fi

  if [[ "$DRY_RUN" == 1 ]]; then
    print_dry_run_plan
    exit 0
  fi

  ensure_vrrp_secret
  save_credentials

  local n
  section "Phase 2: containers + Docker"
  for n in $(all_nodes); do provision_lxc "$n"; done
  verify_same_l2
  # A bootstrap may upgrade Docker or keepalived, which restarts them: nodes without the VIP
  # first, the VIP holder last, after handing the VIP to an upgraded node when an upgrade is
  # waiting (on a first deployment nobody holds it yet).
  local holder; holder=$(vip_holders)
  for n in $(all_nodes | sort -rn); do [[ "$n" == "$holder" ]] || bootstrap_lxc "$n"; done
  if [[ "$holder" =~ ^[0-9]$ ]]; then
    if bootstrap_restarts_services "$holder" && vip_handover_from "$holder"; then
      bootstrap_lxc "$holder"
      vip_handback_pending
      [[ "$DRY_RUN" == 1 ]] || wait_for_failback
    else
      bootstrap_lxc "$holder"
    fi
  fi

  section "Phase 3: Technitium DNS"
  for n in $(all_nodes); do deploy_technitium "$n"; done
  for n in $(all_nodes); do configure_settings "$n"; done
  configure_zones
  verify_dns

  section "Phase 4: keepalived + virtual IP"
  deploy_keepalived 1
  wait_for_vip                  # node 1 claims the VIP first ...
  for n in $(secondary_nodes); do deploy_keepalived "$n"; done   # ... so the others join as BACKUP
  sleep 3
  wait_for_vip
  retire_nodes                  # nodes no longer deployed: out of VRRP and transfers now, so stop them
  verify_vip

  section "Phase 5: optional features"
  for n in $(all_nodes); do configure_unattended "$n"; done
  for n in $(all_nodes); do configure_firewall "$n"; done
  verify_vip                    # VRRP + DNS must still work with the firewall rules in place
  verify_extras
  tech_logout

  section "Phase 6: finalisation"
  for n in $(all_nodes); do configure_resolver "$n"; done
  pin_lxc_hostkeys
  set_lxc_notes

  if [[ -z "$FAILOVER_TEST" ]]; then
    if [[ "$NONINTERACTIVE" == 1 ]]; then
      FAILOVER_TEST=no
    else
      ask_yn FAILOVER_TEST "Run a live failover test now? (~90s; two DNS blips of a few seconds)" yes
    fi
  fi
  [[ "$FAILOVER_TEST" == yes ]] && run_failover_test
  final_report
}

main
