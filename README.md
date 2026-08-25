![Apache Pulsar](https://raw.githubusercontent.com/INAPP-Mobile/pulsar/master/template-icon.svg)

<h1 align="center">Apache Pulsar</h1>
<p align="center"><strong>Distributed streaming platform (Kafka/AMQP alternative) with persistent storage, on Railway</strong></p>
<p align="center">
    <a href="https://railway.com/deploy/qyDotn"><img src="https://railway.app/button.svg" alt="Deploy on Railway" height="40"/></a>
  </p>
  <br/>

# Deploy and Host

**Apache Pulsar** (distributed streaming and messaging platform) on Railway. Single click spins up a single-node standalone broker — broker, BookKeeper, and ZooKeeper metadata in one process — with BookKeeper ledgers and metadata persisted to a Railway volume, so topics and messages survive restarts and deploys.

## About Hosting

Apache Pulsar is a distributed pub-sub streaming platform designed to decouple messaging from compute, storage, and networking. A single standalone node bundles the broker (messaging), BookKeeper (distributed log storage), and ZooKeeper/managed metadata in one process. This template deploys one broker with its data plane on a persistent volume.

## Why Deploy

Self-hosting on Railway gives you full control over your message data. Run event-driven architectures, real-time pipelines, or CDC-style ingestion without managing a cluster. The broker runs a single-node standalone, and the volume keeps BookKeeper ledgers and metadata durable across restarts and deploys.

## Common Use Cases

- Event-driven microservices with async message passing
- Real-time analytics pipelines and data ingestion
- Change data capture (CDC) from databases to downstream consumers
- CQRS/Event Sourcing systems with append-only streams
- IoT telemetry and time-series ingestion
- Kafka/AMQP workloads needing a managed, low-ops broker in your own infra

## Dependencies for Apache Pulsar

### Deployment Dependencies

Apache Pulsar (standalone) is a single self-contained service: broker + BookKeeper + ZooKeeper metadata all run in one process. No companion database is required. BookKeeper ledgers and metadata are written to the attached Railway volume at `/pulsar/data` and survive restarts and deploys.

### Storage

| Item | Detail |
|------|--------|
| **Mount point** | `/pulsar/data` |
| **What's persisted** | BookKeeper ledgers (`bookkeeper/current/ledgers`), ZooKeeper/managed metadata (`metadata`) |
| **Survives** | Restarts, deploys, and image updates |
| **First-boot handling** | The entrypoint `mkdir -p`s `metadata/` and `bookkeeper/` and `chown`s them so the broker (uid 10000) can write its first ledgers on a fresh volume |
| **Data loss risk** | None across normal operation; the volume is backed by Railway's persistent storage |

> Without this volume, every restart re-initializes the broker's log and metadata — all topics and messages are lost. The mount at `/pulsar/data` is what makes the broker durable.

## Features

- **Single-node standalone** — broker + BookKeeper + ZooKeeper metadata in one process; no external cluster to manage.
- **Durable by default** — BookKeeper ledgers and metadata on a Railway persistent volume; topics and messages survive restarts and deploys.
- **Wire protocols** — native `pulsar://` (and `pulsar+ws://` WebSocket) messaging, plus the web/admin HTTP API on `:8080`.
- **Auto-topic creation** enabled out of the box — produce to any topic name immediately.
- **Public + private reach** — the broker advertises the public domain by default for external consumers, and same-project services can reach it over the private network.
- **Health-gated** — the service is only "healthy" once `/admin/v2/clusters` answers `200`, i.e. the full broker+storage stack is ready.

## Quick Start

1. **Deploy** using the button above. Railway creates the broker service and starts the standalone stack.
2. **Attach a Railway volume** at `/pulsar/data` (see *Prerequisites*) so topics/messages are durable.
3. **Connect a client.** The broker listens on `pulsar://<host>:6650` (binary) / `pulsar+ws://<host>:9091` (websocket) / `http://<host>:8080` (admin):

   ```bash
   # produce
   bin/pulsar-client --url pulsar://<host>:6650 \
     produce persistent://public/default/my-topic -m "hello pulsar"

   # consume
   bin/pulsar-client --url pulsar://<host>:6650 \
     consume persistent://public/default/my-topic --subscription my-sub

   # admin (list clusters / topics)
   curl http://<host>:8080/admin/v2/clusters
   curl http://<host>:8080/admin/v2/namespaces/public/default/topics
   ```

4. **Enable public TCP for data ports** (6650/9091) if you want the messaging endpoint exposed beyond the private network (the admin API on 8080 is already public).

## Environment

| Variable | Default | Description |
|----------|---------|-------------|
| `PULSAR_DATA` | `/pulsar/data` | Data directory (BookKeeper ledgers + metadata) on the attached volume. Must match the volume mount point. |
| `PULSAR_ADVERTISED_ADDRESS` | `${RAILWAY_PUBLIC_DOMAIN}` | Host the broker advertises to clients (the destination of `pulsar://:6650`). Set to the private domain to keep same-project traffic off the internet. |

## Prerequisites

- **Recommended: Railway volume at `/pulsar/data`.** Without a volume the broker runs, but all data is wiped on every restart.
- **Data ports for external messaging** are reachable on the private network by default. To expose `pulsar://` to the internet, enable public TCP for `6650` (and optionally `9091`) in the service's Networking settings; the admin API on `8080` is already public.

## Architecture

```
                     ┌────────────────────────────────────────────┐
 external clients    │            Railway service (1 node)         │
 ─── pulsar:// ──────│  broker (messaging)  :6650  :9091          │
   :6650 / :9091 ────│  web/admin  HTTP     :8080  /admin/v2/...   │
   http://:8080 ─────│  in-broker            :2181  ZooKeeper      │
                     │  in-broker            :3181  BookKeeper     │
 same-project ───────│  private network (RAILWAY_PRIVATE_DOMAIN)   │
 network            └───────────────┬─────────────────────────────┘
                                    │  /pulsar/data (persistent volume)
                                    ▼
                          [Railway persistent storage]
```

- **One process, three roles** — broker, BookKeeper, and ZooKeeper/managed metadata all run in a single standalone node (no external cluster).
- **Primary port 8080** — web/admin HTTP; used by the RAILPACK build probe (`/admin/v2/clusters`), the runtime healthcheck, and the public L7 URL.
- **Data plane** — `pulsar://:6650` and `pulsar+ws://:9091` carry the messaging traffic; reach them via the private network or, once public TCP is enabled, the public TCP-proxy endpoint.

## Configuration Reference

| Setting | File / Env | Notes |
|---------|-----------|-------|
| Data directory | `PULSAR_DATA` (default `/pulsar/data`) | `--metadata-dir` and `--bookkeeper-dir` under this path |
| Advertised address | `PULSAR_ADVERTISED_ADDRESS` (default public domain) | `-a` flag on `bin/pulsar standalone` |
| Health path | `railway.json` → `deploy.healthcheckPath` | `/admin/v2/clusters` on `:8080` |
| Health budget | `railway.json` → `deploy.healthcheckTimeout` | 300s (first boot on an empty volume is slow) |

## See Also

- [Apache Pulsar](https://pulsar.apache.org/) — docs and client SDKs
- [Pulsar quickstart](https://pulsar.apache.org/docs/quick-start)
- [Railway persistent volumes](https://docs.railway.app/guides/volumes)
- [Railway public TCP proxy](https://docs.railway.app/deploy/tcp-proxying)
