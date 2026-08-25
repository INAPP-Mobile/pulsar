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
# -a <host> sets the advertised BROKER address (what 6650/9091 clients connect to).
# The embedded BOOKIE address is governed separately by the conf pin above
# (standalone.conf -> bookie 127.0.0.1:3181); -a does not touch it.
#
# SELF-CONNECT LOOPBACK MAP:
#   In standalone mode the stack also starts a Functions Worker whose admin client
#   dials the ADVERTISED web URL during boot. If that URL is the public domain, the
#   request leaves the sandbox, crosses the Railway edge, and comes back — but the
#   edge refuses/502s for unhealth services, so the worker's 30s admin timeout fires
#   before the service finishes booting (observed crash: "Error Starting up in
#   worker ... TimeoutException" -> "Failed to start pulsar service"). Mapping the
#   advertised hostname to 127.0.0.1 in /etc/hosts keeps those INTERNAL connections
#   on loopback (JVM reads /etc/hosts first), while real external clients still
#   resolve the genuine domain through the edge. Skip when ADVERTISE is already
#   loopback or when the file is not writable (harmless no-op).
if [ -n "${ADVERTISE}" ] && [ "${ADVERTISE}" != "localhost" ] \
   && ! printf '%s' "${ADVERTISE}" | grep -qE '^127\.' \
   && printf '127.0.0.1 %s\n' "${ADVERTISE}" >> /etc/hosts 2>/dev/null; then
  echo "[pulsar] /etc/hosts: ${ADVERTISE} -> 127.0.0.1 (worker self-connect via loopback)"
fi

# ---- EMBEDDED-BOOKIE IDENTITY PIN (stable across Railway pod reassignments) ----
# bin/pulsar standalone loads THIS conf file into BOTH the broker and the embedded
# bookie (BKCluster.baseServerConfiguration). With upstream defaults the bookie takes
# BKCluster.newServerConfiguration()'s EPHEMERAL branch (enableLocalTransport defaults
# true -> PortManager.nextLockedFreePort()) and registers <pod-ip>:<random-port>.
# The cookie written into bookkeeper/current/ pins that identity, and every later boot
# RE-ADOPTS it (parseBookieAddressFromCookie overrides conf). On Railway the next
# deploy gets a new pod IP -> unreachable bookie -> NotEnoughBookiesException.
# Fix: force the FIXED-port branch (enableLocalTransport=false + allowEphemeralPorts=
# true + bookiePort!=0 -> port=3181) and advertise 127.0.0.1 (broker and bookie share
# this container; external clients only ever dial the broker on 6650). First boot then
# writes a cookie of 127.0.0.1:3181, valid on every future pod. Quorum 1/1/1 = single
# bookie ensemble.
CONF="${PULSAR_STANDALONE_CONF:-/pulsar/conf/standalone.conf}"
if [ -w "$CONF" ] && ! grep -q '^enableLocalTransport=' "$CONF"; then
  # UPDATE-IN-PLACE: stock standalone.conf already carries some of these keys
  # (e.g. an EMPTY `advertisedAddress=`). Appending a second occurrence makes
  # commons-config see a value list ["", "127.0.0.1"], and the cookie writer then
  # picks the first (empty) entry and falls back to the pod IP — the exact bug
  # this pin exists to prevent. Replace in place, append only if absent.
  pin_conf() {
    key="$1"; val="$2"
    if grep -q "^${key}=" "$CONF"; then
      sed -i "s|^${key}=.*|${key}=${val}|" "$CONF"
    else
      printf '%s=%s\n' "$key" "$val" >> "$CONF"
    fi
  }
  pin_conf enableLocalTransport false
  pin_conf allowEphemeralPorts true
  pin_conf bookiePort 3181
  pin_conf allowLoopback true
  pin_conf advertisedAddress 127.0.0.1
  pin_conf bookkeeperEnsembleSize 1
  pin_conf bookkeeperWriteQuorum 1
  pin_conf bookkeeperAckQuorum 1
  echo "[pulsar] conf pin applied: bookie pinned to 127.0.0.1:3181 ($CONF)"
fi

# ONE-TIME REPAIR for volumes poisoned by an older ephemeral-port boot: if the stored
# cookie holds anything other than the pinned identity, reset BOTH halves of the
# bookie state — the RocksDB metadata store (holds the cluster instanceId) AND the
# bookie dir (holds the matching per-bookie cookie + journals/ledgers). Wiping only
# metadata leaves the old cookie behind and the next boot dies on
# InvalidCookieException (instanceId mismatch). Ledger data is unreadable after a
# metadata reset regardless, so clearing both loses nothing extra; a crash-looping
# broker is worse than a reset namespace. Fresh deploys never hit this branch.
COOKIE="$(grep -rhoE 'bookieHost: "[^"]+"' "${DATA}"/bookkeeper/current 2>/dev/null | head -1 | tr -d '"' )"
COOKIE_ADDR="${COOKIE#bookieHost: }"
if [ -n "${COOKIE_ADDR}" ] && [ "${COOKIE_ADDR}" != "127.0.0.1:3181" ]; then
  echo "[pulsar] stale bookie cookie '${COOKIE_ADDR}' detected — resetting metadata+bookie state to re-pin bookie"
  rm -rf "${DATA:?}/metadata" "${DATA:?}/bookkeeper"
  mkdir -p "${DATA}/metadata" "${DATA}/bookkeeper"
fi

exec bin/pulsar standalone \
  --metadata-dir     "${DATA}/metadata" \
  --bookkeeper-dir   "${DATA}/bookkeeper" \
  -a                 "${ADVERTISE}"
