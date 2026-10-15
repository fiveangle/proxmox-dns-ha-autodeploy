#!/usr/bin/env bash
# Live failover test: stop Technitium on the VIP holder, measure the DNS outage on the VIP,
# start it again and wait for failback to node 1. Causes brief DNS blips (a few seconds).
# Usage: failover-test.sh [--config FILE] [--yes]
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
if [[ "${1:-}" != --yes ]]; then
  answer=""; NONINTERACTIVE=0
  ask_yn answer "This interrupts DNS on $CFG_VIP for a few seconds (twice). Continue?" no
  [[ "$answer" == yes ]] || exit 0
fi
run_failover_test
