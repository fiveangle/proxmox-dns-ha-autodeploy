#!/usr/bin/env bash
# Rolling Technitium upgrade: the BACKUP node first, then the VIP holder (whose VIP briefly
# fails over to the already-updated node). A node whose new container does not become healthy
# is rolled back and the update stops, leaving the other node untouched.
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

update_node() {
  local n=$1 old host
  host=$(node_var "$n" HOST); old=$(current_tag "$n")
  if [[ "$old" == "$TAG" ]]; then ok "$host already runs $TAG"; return 0; fi
  info "$host: $old -> $TAG"
  set_tag "$n" "$TAG"
  if wait_node_ready "$n" "$TAG"; then
    lxc_exec "$n" docker image rm "technitium/dns-server:$old" "docker.io/technitium/dns-server:$old" >/dev/null 2>&1 || true
    ok "$host: running $TAG and healthy"
  else
    err "$host: $TAG did not become healthy within 120s - rolling back to $old"
    set_tag "$n" "$old"
    wait_node_ready "$n" "$old" && warn "$host: rolled back to $old" || err "$host: rollback to $old is not healthy either - check it now"
    die "Update aborted; $(node_var "$(( 3 - n ))" HOST) was not touched"
  fi
}

section "Rolling update to technitium/dns-server:$TAG"
for n in 1 2; do node_reachable "$n" || die "$(node_var "$n" HOST) is not reachable over SSH"; done
holder=$(vip_holders)
[[ "$holder" == 1 || "$holder" == 2 ]] || die "VIP must be held by exactly one node before updating (holders: ${holder:-none})"
for n in 1 2; do
  lxc_query "$n" "$KA_DIR/check_technitium.sh" || die "$(node_var "$n" HOST) is unhealthy - fix it before updating"
done
first=$(( 3 - holder )); second=$holder
printf '  %s: %s   %s: %s   VIP on %s\n' "$CFG_HOST1" "$(current_tag 1)" "$CFG_HOST2" "$(current_tag 2)" "$(node_var "$holder" HOST)"
if [[ "$YES" != yes ]]; then
  answer=""; NONINTERACTIVE=0
  ask_yn answer "Update $(node_var "$first" HOST) first, then $(node_var "$second" HOST)? (brief VIP failover)" yes
  [[ "$answer" == yes ]] || exit 0
fi

info "Pre-pulling the image on both nodes (no service impact)"
for n in 1 2; do lxc_exec "$n" docker pull -q "docker.io/technitium/dns-server:$TAG" >/dev/null; done

probe_start
update_node "$first"
update_node "$second"
read -r probes failed longest < <(probe_stop)

# Keep re-runs of deploy.sh on the new version.
sed -i -E "s|^CFG_IMAGE_TAG=.*|CFG_IMAGE_TAG=$TAG|" "$HELPER_CONFIG"
ok "Both nodes run $TAG ($HELPER_CONFIG updated). DNS on the VIP: $failed of $probes probes failed, longest outage ${longest}s"
if [[ "$second" == 1 ]]; then info "The VIP returns to $CFG_HOST1 about 60s after its update (preempt_delay)"; fi
