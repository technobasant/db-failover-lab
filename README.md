# db-failover-lab

Six database engines, eight failover scenarios on real multi-node clusters, one container per node — and what each one actually preserved.

Every high-availability page ends with the same sentence: the cluster tolerates the loss of a node. It rarely says which node, how long the gap is, whether the write you just acknowledged survived, or what the survivors do while an election runs. I wanted current, measured evidence of that across the engines I work with, so I wrote one test plan and ran it against real multi-node clusters: bring a cluster up, seed known state, kill something, and record what came back.

**8 of 8 scenarios passed my own test plan**, executed on Docker with 8 CPU and 12.5 GB of RAM. I wrote the plan, so the pass rate measures execution, not difficulty — which is why the table below reports what each engine measured rather than a column of PASS.

Write-ups: [the lab, scenario by scenario](https://basantbhattarai.com.np/writing/failover-lab-six-engines-eight-scenarios/) · [case study](https://basantbhattarai.com.np/work/multi-engine-ha-lab/)

## Results

| Engine | Topology | What I broke | What came back | Measured |
|---|---|---|---|---|
| PostgreSQL 18 | Primary + hot standby on a replication slot | `pg_promote()` on the standby | Standby left recovery, timeline 1 → 2, writes accepted | Replay lag **383 µs**, write lag 104 µs ¹ |
| Redis 8 Sentinel | 1 primary + 2 replicas + 3 sentinels, quorum 2 | Stopped the primary | Replica promoted; canary key intact; old primary rejoined as a replica | **~5 s** to a writable replica ² |
| Redis 8 Cluster | 3 primaries + 3 replicas, 16,384 slots | `docker kill` on a primary | Its replica promoted; `cluster_state:ok`, all 16,384 slots covered; seeded keys intact | Config epoch **2 → 7** |
| MariaDB 11.8 + Galera 4 | 3-node multi-master | 150 concurrent `UPDATE`s of one row from two masters | Certification failures on two nodes (3 and 5), 2 BF aborts — and the counter converged | **300 / 300 / 300** on all three nodes |
| MariaDB 11.8 + Galera 4 | 3-node multi-master | Graceful stop of two nodes, then `docker kill` of two | Graceful: survivor stayed Primary. Ungraceful: survivor went non-Primary and rejected writes (`ERROR 1047`) | Quorum loss only on ungraceful exit |
| MongoDB 8.0 | 3-node replica set | Stopped the primary | New primary elected; `w:"majority"` write succeeded on it | 1,000 / 1,000 docs replicated |
| MongoDB 8.0 | Config server + 2 shards + `mongos` | 100,000 docs on a hashed `userId` key | Targeted query hit 1 shard; a non-key filter scatter-gathered to both | **49,607 / 50,393** shard split |
| ScyllaDB 2026.1 | 3 nodes, RF=3, 256 vnodes each | One node stopped, read at `QUORUM` | Read served from the surviving replicas | 3 / 3 rows; 3 endpoints held the key |
| ScyllaDB 2026.1 | Same | `TRUNCATE`, then snapshot restore | Restored after `DROP` + recreate + load from `upload/` + `nodetool refresh` | 3 / 3 rows restored |
| SolrCloud 9 | ZooKeeper + 2 nodes, 2 shards × 2 replicas | Stopped one node | Cluster went ORANGE and kept answering; back to GREEN once the node restarted | `numFound` **6** throughout |
| Prometheus + Grafana | Exporters → Prometheus → Grafana | — | Postgres, Redis and Prometheus targets up; dashboard auto-provisioned | Redis keyspace hits / misses 500 / 500 |
| Network partition | — | Asymmetric partition | **Not tested** — one Docker host cannot produce a split network | — |

¹ A single `pg_stat_replication` reading with primary and standby on the same machine: loopback, no network. It is a floor for the configuration, not a latency to expect across hosts.
² Wall-clock from taking the primary down to a writable replica. `down-after-milliseconds` is 5000 in [`redis-sentinel/sentinel.conf`](redis-sentinel/sentinel.conf), so most of that window is the configured detection threshold, not the promotion.

The last row is the limit of the rig, not a result. Every failover here is process death; partition is the case that actually causes split-brain. Full commands and output for every row are in [RESULTS.md](RESULTS.md).

## What cost the most time

The passes were the boring part. These three were version-specific traps no documentation page warned about:

- **ScyllaDB's third node would not start**, with `system does not satisfy minimum AIO requirements`. Seastar reserves async I/O contexts per reactor and the Docker VM's `fs.aio-max-nr` fit two nodes. Raise it VM-wide (it does not survive a Docker Desktop restart). [Write-up](https://basantbhattarai.com.np/writing/scylladb-nodetool-refresh-upload-truncate-marker/)
- **A valid ScyllaDB snapshot restored zero rows, three times, with no error.** `nodetool refresh` only reads the table's `upload/` subdirectory, `TRUNCATE` writes a marker that hides older SSTables, and recreating a table gives it a new UUID directory. [Write-up](https://basantbhattarai.com.np/writing/scylladb-nodetool-refresh-upload-truncate-marker/)
- **Every compose file copied from a PostgreSQL 12–17 guide breaks on 18.** The image wants the volume at `/var/lib/postgresql` with `PGDATA` in an `18/docker` subdirectory, not at `/var/lib/postgresql/data`. [Write-up](https://basantbhattarai.com.np/writing/postgresql-18-docker-volume-path-change/)

## Quick start

**Prerequisites:** Docker 24+ with Docker Compose v2 (`docker compose`, not `docker-compose`), 8 CPU and 12.5 GB of RAM available to the daemon, and about 20 GB of free disk for images and volumes.

**Run one stack at a time.** 12.5 GB does not hold two of these clusters at once, and host memory pressure produces failures that look like engine behaviour. Tear each one down before starting the next.

ScyllaDB needs a larger async-I/O limit on the Docker VM before its third node will start:

```bash
docker run --rm --privileged alpine sysctl -w fs.aio-max-nr=1048576
```

Bring up a stack from the repository root:

```bash
# MongoDB 8.0 — 3-node replica set (then initiate rs0; see RESULTS.md §1a)
docker compose -f mongo-ha/docker-compose.yml up -d

# MongoDB 8.0 — config server + 2 shards + mongos (RESULTS.md §1b)
docker compose -f mongo-shard/docker-compose.yml up -d

# ScyllaDB 2026.1 — start the seed, wait for UN, then add one node at a time (RESULTS.md §2a)
docker compose -f scylla-ha/docker-compose.yml up -d scylla1

# SolrCloud 9 — ZooKeeper + 2 nodes (RESULTS.md §3a)
docker compose -f solr-ha/docker-compose.yml up -d

# MariaDB 11.8 + Galera 4 — bootstrap node 1, wait until healthy, then the joiners (RESULTS.md §4a)
docker compose -f galera-ha/docker-compose.yml up -d galera1
docker compose -f galera-ha/docker-compose.yml up -d galera2 galera3

# Redis 8 Cluster — 6 nodes, then form the cluster (RESULTS.md §5a)
docker compose -f redis-cluster/docker-compose.yml up -d

# Redis 8 Sentinel — 1 primary + 2 replicas + 3 sentinels (RESULTS.md §5d)
docker compose -f redis-sentinel/docker-compose.yml up -d

# PostgreSQL 18 — primary + streaming hot standby (RESULTS.md §6)
docker compose -f pg-replication/docker-compose.yml up -d

# Observability — exporters -> Prometheus -> Grafana (RESULTS.md §7)
docker compose -f observability/docker-compose.yml up -d
```

Each section of [RESULTS.md](RESULTS.md) has the seed data, the fault to inject, and the output to compare against. Tear everything down, volumes included:

```bash
for d in mongo-ha mongo-shard scylla-ha solr-ha galera-ha redis-cluster redis-sentinel \
         pg-replication observability; do
  docker compose -f "$d/docker-compose.yml" down -v
done
```

## Observability

`observability/` runs Postgres and Redis with their exporters, Prometheus on <http://localhost:9091>, and Grafana on <http://localhost:3002> with a Prometheus datasource and a golden-signals dashboard provisioned from [`observability/grafana/provisioning`](observability/grafana/provisioning). The pattern is the same for any engine: an exporter exposes `/metrics`, Prometheus scrapes it, and the dashboard shows latency, traffic, errors and saturation next to the database-specific signals — connections, cache hit ratio, replication lag.

## Repository layout

| Path | What it is |
|---|---|
| `mongo-ha/`, `mongo-shard/` | MongoDB replica set; sharded cluster |
| `scylla-ha/` | ScyllaDB, 3 nodes, RF=3 |
| `solr-ha/` | SolrCloud with ZooKeeper and a shared backup volume |
| `galera-ha/` | MariaDB + Galera, 3-node multi-master |
| `redis-cluster/`, `redis-sentinel/` | Redis Cluster; Redis Sentinel |
| `pg-replication/` | PostgreSQL primary + hot standby |
| `observability/` | Exporters, Prometheus, Grafana |
| `sandbox/` | Single-node engines for quick experiments (`cd sandbox && docker compose --profile sql up -d`) — not part of the measured results |
| `RESULTS.md` | Commands, output and findings for every scenario |

## Decisions

| Decision | Alternative | Why | What it cost |
|---|---|---|---|
| Docker Compose on one host | A VM per node in the cloud | Quorum, election and promotion behaviour is observable at this scale, at zero cost | Network partitions and disk failure are not testable at all |
| One cluster at a time | Everything up at once | 12.5 GB of RAM, and host pressure would masquerade as engine behaviour | No contention testing; every result is an isolated run |
| `docker kill` as well as graceful stop | Graceful shutdown only | Ungraceful loss is the case that breaks quorum — the Galera difference is the whole lesson | Slower resets; some engines needed manual recovery |
| Plain containers, not Kubernetes | Operators on a local cluster | An operator adds its own failover logic on top, which hides the engine behaviour this lab is about | No operator-level lessons here |
| Current 2026 versions | Older LTS releases | I wanted today's failure modes, not the ones in older tutorials | Version-specific traps cost real time (above) |

## Limits

- **One host.** Every failover is process death, not a network partition. A second machine plus `tc`/`netem` is what split-brain testing needs.
- **Idle clusters.** No background writer ran during the faults, which is the easy case. Numbers under sustained load would mean considerably more.
- **Loopback latency.** The Postgres lag is a same-machine floor, not a cross-host expectation.
- **Partly hand-driven.** Several runs were driven from a shell rather than one script, so reproducing a result means following RESULTS.md step by step.
- **Not a production benchmark.** These are behavioural checks with a stated method, not performance claims.

Every password in these compose files (`admin123`, `replpass` and similar) is a throwaway local default for a disposable lab. Do not reuse them anywhere real.

## Related

- [Orchestrated PostgreSQL failover with Patroni, etcd and pgBackRest](https://basantbhattarai.com.np/writing/patroni-postgresql-18-rocky8-etcd-failover/) — the next step after manual `pg_promote()`.

## Licence

[Apache License 2.0](LICENSE). Copyright 2026 Basant Bhattarai.
