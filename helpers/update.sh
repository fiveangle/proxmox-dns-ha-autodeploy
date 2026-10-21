#!/usr/bin/env bash
# Rolling Technitium upgrade, one node at a time: the BACKUP nodes first (lowest priority first),
# then the VIP holder (whose VIP briefly fails over to an already-updated node). Each LXC is
# snapshotted first; a node whose new container does not become healthy is rolled back to that
# snapshot (program and data) and the update stops, leaving the nodes not yet updated untouched.
# The newest pre-update snapshot of each LXC is
# kept as a way back; older ones made by this script are removed.
# Usage: update.sh [--config FILE] [TAG] [--yes]      (TAG defaults to the newest stable release)
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

TAG="" YES=no
for a in "$@"; do case "$a" in --yes) YES=yes ;; *) TAG=$a ;; esac; done
[[ -n "$TAG" ]] || TAG=$(latest_technitium_tag)
[[ -n "$TAG" ]] || die "Could not determine the latest Technitium release; pass a tag"
v_tag "$TAG" || die "Invalid tag: $TAG"
curl -fsS -m 15 -o /dev/null "https://hub.docker.com/v2/repositories/technitium/dns-server/tags/$TAG" \
  || die "technitium/dns-server:$TAG does not exist on Docker Hub"

D=$CFG_SERVICE_DIR
current_tag() { lxc_query "$1" sh -c "sed -nE 's|.*technitium/dns-server:([^[:space:]]+).*|\1|p' '$D/compose.yaml' | head -1"; }

# Node is serving again: container running the expected image, local DNS answers, and
# keepalived has left FAULT (its health check passed `rise` times).
wait_node_ready() {
  local n=$1 tag=$2 i img
  for (( i = 0; i < 60; i++ )); do
    img=$(lxc_query "$n" docker inspect -f '{{.Config.Image}}' technitium 2>/dev/null || true)
    if [[ "$img" == *":$tag" ]] && lxc_query "$n" "$KA_DIR/check_technitium.sh" 2>/dev/null \
       && [[ "$(ka_state "$n")" =~ ^(BACKUP|MASTER)$ ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

set_tag() {  # set_tag N TAG — rewrite the image tag in compose.yaml and (re)create the container
  local n=$1 tag=$2
  lxc_exec "$n" sed -i -E "s|(technitium/dns-server:)[^[:space:]]+|\1$tag|" "$D/compose.yaml"
  lxc_exec "$n" docker compose --project-directory "$D" up -d --quiet-pull >/dev/null 2>&1
}

SNAP_PREFIX=pdha_preupdate_

# take_snapshot N OLD_TAG — prints the snapshot name, or nothing if the storage can't snapshot
take_snapshot() {
  local n=$1 name
  name="$SNAP_PREFIX$(date +%Y%m%d%H%M%S)"
  node_exec "$n" pct snapshot "$(node_var "$n" VMID)" "$name" \
    --description "Before Technitium update $2 -> $TAG (helpers/update.sh)" >/dev/null 2>&1 && echo "$name"
}

# prune_snapshots N KEEP — remove this script's older pre-update snapshots of node N
prune_snapshots() {
  local n=$1 keep=$2 vmid s
  vmid=$(node_var "$n" VMID)
  for s in $(node_exec "$n" pct listsnapshot "$vmid" | grep -oE "${SNAP_PREFIX}[0-9]+" | sort -u); do
    [[ "$s" == "$keep" ]] || node_exec "$n" pct delsnapshot "$vmid" "$s" >/dev/null 2>&1 || true
  done
}

update_node() {
  local n=$1 old host vmid snap m
  host=$(node_var "$n" HOST); vmid=$(node_var "$n" VMID); old=$(current_tag "$n")
  if [[ "$old" == "$TAG" ]]; then ok "$host already runs $TAG"; return 0; fi
  info "$host: $old -> $TAG"
  snap=$(take_snapshot "$n" "$old" || true)
  [[ -n "$snap" ]] && ok "$host: snapshot $snap taken (CT $vmid)" \
    || warn "$host: could not snapshot CT $vmid - a failed update can only restore the image, not data"
  set_tag "$n" "$TAG"
  if [[ "${PDHA_TEST_BREAK_UPDATE:-}" == 1 ]]; then  # test hook: simulate a release that changes data, then dies
    warn "PDHA_TEST_BREAK_UPDATE=1: simulating a broken $TAG on $host"
    lxc_exec "$n" touch "$D/.pdha-test-marker"
    lxc_exec "$n" docker stop technitium >/dev/null
  fi
  if wait_node_ready "$n" "$TAG"; then
    lxc_exec "$n" docker image rm "technitium/dns-server:$old" "docker.io/technitium/dns-server:$old" >/dev/null 2>&1 || true
    [[ -z "$snap" ]] || prune_snapshots "$n" "$snap"
    ok "$host: running $TAG and healthy"
    UPDATED+=("$n")
  else
    if [[ -n "$snap" ]]; then
      err "$host: $TAG did not become healthy within 120s - rolling CT $vmid back to snapshot $snap"
      node_exec "$n" pct stop "$vmid" >/dev/null 2>&1 || true
      node_exec "$n" pct rollback "$vmid" "$snap" --start 1 >/dev/null
    else
      err "$host: $TAG did not become healthy within 120s - rolling back to $old"
      set_tag "$n" "$old"
    fi
    wait_node_ready "$n" "$old" && warn "$host: rolled back to $old" || err "$host: rollback to $old is not healthy either - check it now"
    local updated="" untouched=""
    for m in "${ORDER[@]}"; do
      if [[ "$(current_tag "$m")" == "$TAG" ]]; then updated+="$(node_var "$m" HOST) "; continue; fi
      [[ "$m" == "$n" ]] || untouched+="$(node_var "$m" HOST) "
      # drop the pre-pulled image where it is not running
      lxc_exec "$m" docker image rm "docker.io/technitium/dns-server:$TAG" >/dev/null 2>&1 || true
    done
    read -r probes failed longest < <(probe_stop)
    info "DNS on the VIP during the attempt: $failed of $probes probes failed, longest outage ${longest}s"
    [[ -z "$updated" ]] || warn "Already on $TAG: ${updated}- run update.sh again once the problem is fixed, or update.sh <old tag> to go back"
    die "Update aborted${untouched:+; not touched: ${untouched% }}"
  fi
}

section "Rolling update to technitium/dns-server:$TAG"
for n in $(all_nodes); do node_reachable "$n" || die "$(node_var "$n" HOST) is not reachable over SSH"; done
holder=$(vip_holders)
[[ "$holder" =~ ^[0-9]$ ]] || die "VIP must be held by exactly one node before updating (holders: ${holder:-none})"
for n in $(all_nodes); do
  lxc_query "$n" "$KA_DIR/check_technitium.sh" || die "$(node_var "$n" HOST) is unhealthy - fix it before updating"
done
# Lowest priority first; the VIP holder last.
ORDER=()
for n in $(all_nodes | sort -rn); do [[ "$n" == "$holder" ]] || ORDER+=("$n"); done
ORDER+=("$holder")
printf '  '; for n in $(all_nodes); do printf '%s: %s   ' "$(node_var "$n" HOST)" "$(current_tag "$n")"; done
printf 'VIP on %s\n' "$(node_var "$holder" HOST)"
if [[ "$YES" != yes ]]; then
  answer=""; NONINTERACTIVE=0
  names=(); for n in "${ORDER[@]}"; do names+=("$(node_var "$n" HOST)"); done
  ask_yn answer "Update $(and_list "${names[@]}") in that order? (brief VIP failover)" yes
  [[ "$answer" == yes ]] || exit 0
fi

info "Pre-pulling the image on $(all_word) nodes (no service impact)"
for n in $(all_nodes); do lxc_exec "$n" docker pull -q "docker.io/technitium/dns-server:$TAG" >/dev/null; done

UPDATED=()
probe_start
for n in "${ORDER[@]}"; do update_node "$n"; done
read -r probes failed longest < <(probe_stop)

# Keep re-runs of deploy.sh on the new version.
sed -i -E "s|^CFG_IMAGE_TAG=.*|CFG_IMAGE_TAG=$TAG|" "$HELPER_CONFIG"
ok "$( (( $(node_count) == 2 )) && echo 'Both nodes run' || echo "All $(node_count) nodes run") $TAG ($HELPER_CONFIG updated). DNS on the VIP: $failed of $probes probes failed, longest outage ${longest}s"
if [[ "$holder" == 1 && " ${UPDATED[*]} " == *" 1 "* ]]; then info "The VIP returns to $CFG_HOST1 about 60s after its update (preempt_delay)"; fi
