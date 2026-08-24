#!/usr/bin/env bash
# Runtime health helper (also used in the Dockerfile HEALTHCHECK and by the RAILPACK
# build probe). Returns 0 (healthy) only once the standalone broker has finished
# initializing its full stack (ZooKeeper + BookKeeper + broker) — the /admin/v2/clusters
# endpoint is served by the web/admin server and 200 only when the cluster is up.
# Uses 127.0.0.1 (not localhost) so gVisor's ::1-first resolution cannot break the probe.
set -euo pipefail
PORT="${PORT:-8080}"
exec curl -fsS -o /dev/null --max-time 10 "http://127.0.0.1:${PORT}/admin/v2/clusters"
