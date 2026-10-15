# proxmox-dns-ha-autodeploy

**From an empty Proxmox host to a redundant, tested DNS pair - with one command.**

`deploy.sh` creates two Debian 13 LXCs, installs Docker and
[Technitium DNS Server](https://technitium.com/dns/), puts a floating virtual IP in front of them
with keepalived, syncs your zones between them, and verifies the whole thing - including a live
failover test. No Proxmox cluster required, and nothing to set up by hand: give clients the one
VIP, and if a server goes down the other answers within seconds.

Answer a short series of questions (each with a sensible default), or re-run it unattended from
a saved answers file.

## Highlights

- **Fast, verified failover** - typical DNS outage on the VIP of **~3 s** when the active server
  fails, and **0 s** when it comes back (failback waits 60 s for it to be fully ready, then hands
  over seamlessly). A live failover test can run at the end of every deployment.
- **Survives a host failure** - place the second server on a **separate, non-clustered Proxmox
  host** over SSH; the script handles the key exchange, per-host storage and network choices.
- **Zero-downtime upgrades** - `helpers/update.sh` upgrades Technitium one node at a time
  (measured **< 1 s** of VIP impact) and rolls a node back automatically if the new version
  is not healthy.
- **Local zones that never break the internet** - records you add are answered locally; names not
  in the zone are forwarded upstream, so a public domain you own keeps working for every host you
  have not defined. Add more zones any time with `helpers/zones.sh`.
- **Edit once, served twice** - changes made on ns1 reach ns2 automatically in ~10 s via zone
  transfer (locked to the two servers). Optional reverse (PTR) zone included.
- **Private, validated upstream** - DNS-over-HTTPS to Cloudflare, Quad9 or Google (or your own),
  DNSSEC validation, serve-stale, recursion limited to private networks.
- **Health-checked, not just alive** - keepalived moves the VIP when Technitium stops *answering*,
  not only when the LXC dies; no split brain (both nodes never hold the VIP at once).
- **Optional extras, chosen at deploy time** - ad/malware blocklists, HTTPS web UI, Proxmox
  firewall rules, unattended security upgrades, extra apt packages (tmux, btop, ...).
- **Safe by design** - pre-flight checks before anything is created (free VMIDs and IPs, VRRP ID
  collisions on the LAN, storage space, upstream reachability); a `--dry-run` mode; idempotent
  re-runs; the admin password never on a command line and stored root-only on the host, with a
  recovery tool if it is lost.
- **Clean layout** - bind mounts only, everything under one service directory
  (`/srv/technitium` by default): easy to back up, inspect and move.

## Simple by design

High availability here is built from standard parts. It doesn't depend on any feature of the
DNS server itself.

- **No application-specific DNS clustering** - this does **not** use Technitium's built-in
  clustering. Each node is a standalone Technitium server. Failover is plain VRRP (keepalived)
  on the Linux network stack, and replication is standard DNS zone transfer with NOTIFY, the same
  primary/secondary setup DNS has used for decades. There's no cluster state to keep healthy, no
  cluster-specific failure modes, and nothing extra to learn. During a rolling upgrade the two
  nodes can run different Technitium versions side by side, because zone transfer doesn't
  depend on the version. Everything Technitium-specific is in one file (`lib/technitium.sh`).
- **No split-DNS complexity** - clients use one address, the VIP, and get one consistent answer.
  You don't maintain separate internal and external views, and you don't keep an internal copy
  of your public zone. A local zone answers only the records you add to it and forwards every
  other name upstream, so `nas.example.com` resolves locally while `www.example.com` still
  reaches your public DNS.

## Requirements

- Proxmox VE 8 or newer (tested on 9.2), run as root on the host.
- Two free IPs plus one for the VIP, all on the same L2 network.
- Internet access from the host and the LXCs (Debian, Docker and Docker Hub).
- For a second host: root SSH from the first host (the script offers to install the key).

## Quick start

```bash
./deploy.sh                 # interactive; answers are saved for re-runs
./deploy.sh --dry-run       # questions + pre-flight checks, then print every action
./deploy.sh --config /root/proxmox-dns-ha-autodeploy/deploy.conf   # unattended re-run
```

See **[deploy.conf.example](deploy.conf.example)** for every setting (nodes, network, zones,
upstream, optional features, image tag) with comments. State lives in `/root/proxmox-dns-ha-autodeploy/`
on the host: `deploy.conf`, `credentials` (admin password, root-only) and logs.

## Day-2 helpers

Run on the Proxmox host; they reach both LXCs directly over SSH, on one host or two.

| Command | Purpose |
|---|---|
| `helpers/status.sh` | VIP holder, keepalived state, container health, zone sync (exit 1 on problems) |
| `helpers/update.sh [tag]` | Rolling Technitium upgrade (newest release by default) with auto-rollback |
| `helpers/zones.sh list \| add ZONE... \| remove ZONE` | Manage additional local zones on both servers |
| `helpers/failover-test.sh` | Repeat the live failover/failback test and report outage times |
| `helpers/reset-admin.sh [1\|2\|all]` | Reset the web UI admin password, keeping users, zones and settings |

## After deployment

1. Point your DHCP server's DNS option at the VIP.
2. Manage records in the web UI on **ns1** (`https://<ns1-ip>:53443` by default, or
   `http://<ns1-ip>:5380` if you turned HTTPS off); login `admin`, password in
   `/root/proxmox-dns-ha-autodeploy/credentials`.

**Tip:** each LXC's **Notes** panel in the Proxmox UI has a quick reference for that server: its
role, its peer, the VIP, a web UI link, its zones and the helper commands. The notes are rewritten
on every deploy, so they stay current.

Design decisions and test results are documented in [PLAN.md](PLAN.md).

---
proxmox-dns-ha-autodeploy - by David Johnson ([@fiveangle](https://github.com/fiveangle))
