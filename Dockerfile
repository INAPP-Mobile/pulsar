# Upstream: apachepulsar/pulsar (Apache Pulsar — distributed streaming platform)
# Single-node standalone = broker + ZooKeeper + BookKeeper in one process.
#
# Pinned stable release (floating tags are banned by the repo gate; dependabot-managed). v4.2.4
FROM apachepulsar/pulsar:4.2.4

# Apache Pulsar ships as user `pulsar` (uid 10000). A FRESH Railway volume is
# root-owned and not world-writable, so the non-root data plane cannot create its
# ledger/metadata files on first attach (the exact failure the redpanda data-service
# template avoids). We therefore run as root (repo "prefer root" data-service pattern)
# so BookKeeper/ZooKeeper can lay down and persist ledgers on the attached volume.
# This is a single-node dev/demo-grade broker, not a hardened HA cluster.
USER root

COPY entrypoint.sh /usr/local/bin/pulsar-entrypoint.sh

# Primary port = 8080, the broker's web/admin HTTP server (native). This is the port
# Railway's RAILPACK build probe, the runtime healthcheck, and the public L7 URL all
# target (health path /admin/v2/clusters). The binary data plane:
#   6650  pulsar://      (external clients: L4 public TCP or private network)
#   9091  pulsar+ws://   (WebSocket, same two paths)
#   2181  ZooKeeper (standalone)
#   3181  BookKeeper
ENV PORT=8080
ENV PULSAR_DATA=/pulsar/data
EXPOSE 8080 6650 9091

# Healthcheck probes the PRIMARY port (8080) /admin/v2/clusters — returns 200 only
# after the full standalone stack (ZooKeeper + BookKeeper + broker) is ready. 127.0.0.1
# (not localhost) so gVisor's ::1-first resolution can't break the probe. Generous
# start-period + retries: JVM + RocksDB init is slow on a cold, first-boot (empty
# volume) start; the runtime healthcheck allows up to ~300s and keeps the replica up.
HEALTHCHECK --interval=15s --timeout=15s --start-period=300s --retries=20 \
  CMD curl -fsS -o /dev/null http://127.0.0.1:8080/admin/v2/clusters || exit 1

ENTRYPOINT ["bash", "/usr/local/bin/pulsar-entrypoint.sh"]
