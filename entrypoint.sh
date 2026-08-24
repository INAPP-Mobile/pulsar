#!/usr/bin/env bash
# Apache Pulsar — single-node standalone (broker + ZooKeeper + BookKeeper).
#
# Native ports (all bound on 0.0.0.0):
#   8080  web/admin HTTP     -> PRIMARY: public L7 URL, RAILPACK build probe, runtime healthcheck
#   6650  pulsar:// binary   -> data plane (external via Railway L4 public TCP, or private network)
#   9091  pulsar+ws://       -> WebSocket data plane (same two paths)
#   2181  ZooKeeper          (standalone, in-broker)
#   3181  BookKeeper
#
# Advertised address = the host the broker tells every client to CONNECT to. It MUST be
# an address that the client can actually route to:
#   - same-project services  -> use ${RAILWAY_PRIVATE_DOMAIN}  (zero egress, preferred internally)
#   - external (internet)    -> use the public endpoint (L4 proxy domain for 6650/9091,
#                              or the public domain once the service has a public URL)
# Default to the PUBLIC domain so the broker is reachable from outside by default (the
# point of deploying a standalone broker); point it at the private domain to keep
# same-project traffic off the internet.
#
# Client connect examples (once public TCP for 6650 is enabled):
#   pulsar://   <host>:6650     (broker)
#   pulsar+ws://<host>:9091     (websocket)
#   http://     <host>:8080     (web/admin)
set -e

DATA="${PULSAR_DATA:-/pulsar/data}"
ADVERTISE="${PULSAR_ADVERTISED_ADDRESS:-${RAILWAY_PUBLIC_DOMAIN:-localhost}}"

# Data plane dirs on the attached (persistent) volume. mkdir -p keeps it a no-op when
# the volume is empty and re-uses it when it is not, so ledgers/metadata SURVIVE restarts.
mkdir -p "${DATA}/metadata" "${DATA}/bookkeeper"
# Running as root here (Dockerfile); ensure the tree is writable by whichever user
# Pulsar's child processes run as.
chown -R root:root "${DATA}" 2>/dev/null || true

echo "[pulsar] data           = ${DATA}"
echo "[pulsar] advertised     = ${ADVERTISE}"
echo "[pulsar] web/admin :8080   broker :6650   websocket :9091   zk :2181   bookie :3181"
echo "[pulsar] connecting     : pulsar://${ADVERTISE}:6650   http://${ADVERTISE}:8080"

# `exec` replaces the shell with Pulsar so it becomes PID 1 and owns SIGTERM (clean
# shutdown on Railway redeploy/stop). --metadata-dir/--bookkeeper-dir keep the state on
# the attached volume instead of the container's (ephemeral) default /pulsar/data dir.
#
# -a <host> sets the advertised broker address (what 6650/9091 clients connect to).
# bin/pulsar standalone wires the web (8080), broker (6650), ws (9091), ZK (2181) and
# BookKeeper (3181) listeners internally — no external config file needed.
exec bin/pulsar standalone \
  --metadata-dir     "${DATA}/metadata" \
  --bookkeeper-dir   "${DATA}/bookkeeper" \
  -a                 "${ADVERTISE}"
