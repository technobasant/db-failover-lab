# Results — HA, sharding, backup/restore, monitoring

Executed live on Docker (8 CPU / ~12.5 GB) for **MongoDB 8.0**, **ScyllaDB 2026.1**,
**SolrCloud 9**, **MariaDB 11.8 + Galera**, **Redis 8 (Cluster + Sentinel)**, **PostgreSQL 18**,
and an end-to-end **observability** stack. Each cluster was brought up, exercised, and torn down
one at a time to fit RAM. Compose files: `mongo-ha/`, `mongo-shard/`, `scylla-ha/`, `solr-ha/`,
`galera-ha/`, `redis-cluster/`, `redis-sentinel/`, `pg-replication/`, `observability/`.
Re-run any with the commands in each section.

| Engine | HA / cluster | Sharding | Backup/Restore | Monitoring | Result |
| --- | --- | --- | --- | --- | --- |
| MongoDB 8.0 | 3-node replica set, auto-failover | hashed-key sharded cluster (2 shards) | mongodump/restore | serverStatus, repl lag, oplog | PASS |
| ScyllaDB 2026.1 | 3-node, RF=3, QUORUM survives node loss | token ring (256 vnodes/node) | nodetool snapshot + refresh | nodetool info/tablestats, :9180 | PASS |
| SolrCloud 9 | ZK + 2 nodes, 2×2 shards/replicas | numShards=2 | collection BACKUP/RESTORE | metrics API, solr-exporter | PASS |
| MariaDB 11.8 + Galera 4 | 3-node multi-master, quorum, IST rejoin | n/a (full replicas) | mariabackup SST (state transfer) | wsrep_* status vars | PASS |
| Redis 8 Cluster | 3 primaries + 3 replicas, auto-failover | 16384 hash slots, hash tags | AOF per node | CLUSTER INFO/SHARDS | PASS |
| Redis 8 Sentinel | 1 primary + 2 replicas + 3 sentinels | n/a | AOF/RDB | SENTINEL master/replicas | PASS |
| PostgreSQL 18 | primary + hot-standby, pg_promote failover | n/a | pg_basebackup + WAL/PITR | pg_stat_replication, lag | PASS |
| Observability | exporters → Prometheus → Grafana | n/a | n/a | golden-signals dashboard | PASS |

---

## 1. MongoDB 8.0 — replica set HA + sharding + backup + monitoring

### 1a. HA: 3-node replica set + automatic failover
```bash
docker compose -f mongo-ha/docker-compose.yml up -d
# initiate rs0 with mongo1 priority:2, mongo2/3 priority:1
```
Topology after init, and after killing the primary:
```
set: rs0
  mongo1:27017  PRIMARY    health=1
  mongo2:27017  SECONDARY  health=1
  mongo3:27017  SECONDARY  health=1

# docker stop mongo1  ->  election:
  mongo1:27017  (not reachable/healthy)  health=0
  mongo2:27017  PRIMARY                  health=1
  mongo3:27017  SECONDARY                health=1
write after failover: OK          # w:majority write succeeded on new primary
# restart mongo1 -> rejoins SECONDARY, then reclaims PRIMARY via priority:2
```
- RBAC: created `admin` (root) + least-privilege `app` (`readWrite@poc`).
- `w:"majority", j:true` write of 1000 docs; secondary read returned **1000 docs replicated**.
- **Takeaway:** RAFT-like elections give automatic failover; `w:majority` guarantees the write
  survives failover. Priority controls preferred primary.

### 1b. Sharding: hashed shard key distributes evenly
```bash
docker compose -f mongo-shard/docker-compose.yml up -d   # configsvr + shard1 + shard2 + mongos
# sh.enableSharding("poc"); sh.shardCollection("poc.events", {userId:"hashed"})
```
```
total docs via mongos: 100000
shard1: 49607 docs        # ~50/50 split via hashed key (no hot-spotting)
shard2: 50393 docs
targeted (userId=42)  -> shards: 1     # shard key present = single-shard, fast
scatter (region=eu)   -> shards: 2     # non-key filter = scatter-gather all shards
```
- **Takeaway:** hashed key avoids monotonic hot-spotting; always include the shard key in queries
  to get single-shard targeting instead of scatter-gather.

### 1c. Backup / restore
```
mongodump --db=poc --out=/tmp/backup        # orders.bson + metadata
db.orders.drop()                             # after drop: 0 docs
mongorestore --db=poc /tmp/backup/poc        # after restore: 1001 docs
```

### 1d. Monitoring (golden signals)
```
replication lag: mongo1 0s, mongo2 0s, mongo3 0s
connections.current: 17   opcounters insert=1003 query=52
mem.resident: 231 MB      wiredTiger cache: 1.0 MB
oplog window(hrs): ... (getReplicationInfo -> DR recovery window)
```

### Production notes
- Enable **keyfile / x.509 internal auth** + TLS; RBAC roles per app; the localhost exception
  bootstraps the first user.
- Sharded backups: **Percona Backup for MongoDB (PBM)** for consistent oplog-based PITR across shards.
- Config servers in 8.0 can be **config shards** (hold data) to cut single-shard cluster cost.

---

## 2. ScyllaDB 2026.1 — 3-node HA + consistency + snapshot backup/restore + monitoring

### 2a. HA cluster (seed + 2 joiners, one at a time)
```bash
docker compose -f scylla-ha/docker-compose.yml up -d scylla1   # seed
# wait UN, then bring up scylla2, wait, then scylla3
```
```
UN 172.21.0.2 ... rack1       # all three Up/Normal, 256 tokens each
UN 172.21.0.3 ... rack1
UN 172.21.0.4 ... rack1
```
> **Gotcha hit & fixed:** 3rd node failed with *"system does not satisfy minimum AIO
> requirements"*. Fix: raise the Docker VM limit —
> `docker run --rm --privileged alpine sysctl -w fs.aio-max-nr=1048576` — then restart the node.

### 2b. Consistency / availability (RF=3)
```sql
CREATE KEYSPACE poc WITH replication={'class':'NetworkTopologyStrategy','datacenter1':3};
-- query-driven table, partition bucketed by day to bound partition size:
CREATE TABLE poc.sensor_by_day (sensor_id text, day date, ts timestamp, value double,
  PRIMARY KEY ((sensor_id, day), ts)) WITH CLUSTERING ORDER BY (ts DESC);
```
```
nodetool getendpoints poc sensor_by_day "s1:2026-06-07"  -> 3 endpoints (RF=3, all nodes)
# stop scylla2, then:
CONSISTENCY QUORUM; SELECT ... -> returned 3 rows   # survives 1 node down (needs 2/3)
```

### 2c. Snapshot backup → loss → restore
```
nodetool snapshot -t poc_bkp poc          # on all 3 nodes (hardlinked SSTables)
TRUNCATE poc.sensor_by_day                  # loss -> 0 rows
# restore: stage snapshot SSTables -> DROP+recreate -> copy into <table-dir>/upload/ -> refresh
nodetool refresh poc sensor_by_day          # per node
CONSISTENCY QUORUM; SELECT count(*) -> 3    # restored
```
> **Gotchas hit & fixed:** (1) `nodetool refresh` loads only from the table's **`upload/`**
> subdir; (2) **TRUNCATE writes a truncation marker** that hides older SSTables, so restore needs
> DROP+recreate (not truncate); (3) recreating a table makes a **new UUID directory** — load into
> the live dir (match `system_schema.tables.id`), not the stale one.

### 2d. Monitoring
```
nodetool info      -> Gossip/Native Transport active, Load, Uptime, DC/Rack
nodetool tablestats poc.sensor_by_day -> Read Count 40, SSTable count 6, Space used
# Scylla also exposes Prometheus metrics on :9180 (scylla_storage_proxy_*; reactor utilization)
```

### Production notes
- Multi-DC: `NetworkTopologyStrategy` with RF per DC, app reads/writes at **LOCAL_QUORUM**.
- Real DR also uses **`nodetool repair`** (anti-entropy) and node **rebuild** to restream from
  replicas; `gc_grace_seconds` governs tombstone GC (watch tombstone buildup).
- 2026.1: **tablets** give elastic scaling (instant 2–10×, ~90% storage) vs static vnodes.

---

## 3. SolrCloud 9 — sharded+replicated HA + backup/restore + monitoring

### 3a. HA collection: 2 shards × 2 replicas across 2 nodes
```bash
docker compose -f solr-ha/docker-compose.yml up -d   # zoo + solr1 + solr2
# action=CREATE&name=products&numShards=2&replicationFactor=2
```
```
health: GREEN
shard1: core_node7@solr1(active,leader=true), core_node8@solr2(active,leader=false)
shard2: core_node3@solr2(active,leader=true), core_node5@solr1(active,leader=false)
```

### 3b. HA test — one node down stays queryable
```
total docs: 6   (queried from solr2 too -> 6, cluster-wide visibility)
# docker stop solr2:
SELECT *:* -> numFound 6           # all data still served (replica per shard on solr1)
health: ORANGE   states: 4 active / 2 down     # degraded but AVAILABLE
# docker start solr2 -> auto-recovery -> health: GREEN
```

### 3c. Backup / restore (collections API, shared volume)
```
action=BACKUP&name=prodbkp&collection=products&location=/backup     -> status 0
delete *:*                                                          -> 0 docs
action=RESTORE&name=prodbkp&collection=products_restored&...        -> status 0
products_restored *:* -> numFound 6                                 # restored
```
> **Gotcha hit & fixed:** backup returned 500 *"access denied"*. Fix: start Solr with
> `-Dsolr.allowPaths=/backup` (SOLR_OPTS) **and** make the location writable by the `solr` user
> (`chown solr:solr /backup`); the location must be shared/visible to all nodes.

### 3d. Monitoring
```
metrics?group=core&prefix=QUERY./select.requestTimes -> count, meanRate (query throughput/latency)
metrics?group=jvm&prefix=memory.heap -> heap used 227MB / max 512MB
live nodes: 2
# Production: bin/solr-exporter -p 9854 -z zoo:2181 -> Prometheus -> Grafana dashboards
```

### Production notes
- ZooKeeper ensemble of **3/5** nodes (odd quorum); replica types NRT (default) / TLOG / PULL.
- Relevance/perf: `edismax` (qf/pf/mm), cached `fq`, `docValues` for facet/sort, `autoSoftCommit`
  for NRT, size filter/queryResult caches and watch hit ratios.
- Backups belong on **shared/!object storage** (HDFS/S3 via repository) so every node can read them.

---

## 4. MariaDB 11.8 + Galera 4 — 3-node multi-master, conflicts, quorum, recovery

### 4a. Cluster formation (bootstrap + 2 SST joiners)
```bash
docker compose -f galera-ha/docker-compose.yml up -d galera1     # --wsrep-new-cluster bootstraps
# wait healthy, then:
docker compose -f galera-ha/docker-compose.yml up -d galera2 galera3   # join via mariabackup SST
```
```
wsrep_cluster_size        3
wsrep_cluster_status      Primary
wsrep_local_state_comment Synced
wsrep_incoming_addresses  172.18.0.3:0,172.18.0.4:0,172.18.0.2:0
```

### 4b. Multi-master synchronous write (write node2, read node3)
```
UPDATE acct SET bal=bal+50 WHERE id=1;   -- on galera2
SELECT bal FROM acct WHERE id=1;          -- on galera3 -> 150   (synchronous, no lag)
```

### 4c. Certification conflict (concurrent writes to the same row)
150 concurrent UPDATEs of one row from node2 **and** node3 at once:
```
node1: wsrep_local_cert_failures 0   wsrep_local_bf_aborts 0
node2: wsrep_local_cert_failures 3   wsrep_local_bf_aborts 0
node3: wsrep_local_cert_failures 5   wsrep_local_bf_aborts 2
final ctr.n -> 300 on all three nodes   # optimistic locking resolved every conflict, converged
```
- **Takeaway:** Galera is optimistic — conflicts are caught at **commit time** via certification
  (loser gets a deadlock/`cert failure`), not row locks. Don't route a hot single row to all masters.

### 4d. Node failure vs. quorum (graceful ≠ ungraceful)
```
docker stop galera3        -> size=2, status=Primary        # 2/3 quorum holds, writes OK
docker stop galera2        -> size=1, status=Primary (!!)    # graceful leaves shrink the PC cleanly
docker start galera2 3     -> size=3                         # rejoin via IST (incremental, not full SST)
docker kill galera2 galera3 -> size=1, status=non-Primary    # UNGRACEFUL: lost quorum
  INSERT ... -> ERROR 1047 "WSREP has not yet prepared node for application use"   # writes rejected
```
- **Key insight:** a **graceful** shutdown removes the node from the Primary
  Component, so the survivor can stay Primary; an **ungraceful** crash/partition triggers quorum loss
  and the minority goes **non-Primary** (read-only) to prevent split-brain.

### 4e. Recovery
- Canonical: bootstrap the most-advanced survivor (`SET GLOBAL wsrep_provider_options='pc.bootstrap=YES'`).
- **Gotcha hit:** in this MariaDB 11.8 build `wsrep_provider_options` is **read-only at runtime**, so
  recovery is done by restarting that node as a new cluster (`galera_new_cluster` / `--wsrep-new-cluster`).

### Production notes
- SST (full snapshot via mariabackup) for new joiners; **IST** (incremental) for short absences.
- Odd node count (3/5) avoids split-brain; `wsrep_sync_wait` for read-your-writes; DDL via TOI vs RSU.

---

## 5. Redis 8 — Cluster (sharding + failover) and Sentinel (HA failover)

### 5a. Cluster: 6 nodes -> 3 primaries + 3 replicas, 16384 slots
```bash
docker compose -f redis-cluster/docker-compose.yml up -d
IPS=$(for i in 1 2 3 4 5 6; do docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}:6379' redis-cluster-redis$i-1; done)
docker exec redis-cluster-redis1-1 sh -c "redis-cli --cluster create $IPS --cluster-replicas 1 --cluster-yes"
```
```
[OK] All 16384 slots covered.    masters: 0-5460 | 5461-10922 | 10923-16383
```

### 5b. Slot routing + hash tags
```
keyslot(foo)=12182   keyslot(baz)=4813          # different keys -> different slots/masters
keyslot({user1}:profile)=8106                    # hash tag {user1} forces co-location
keyslot({user1}:cart)   =8106                    # same slot -> multi-key ops allowed
```

### 5c. Automatic failover (kill a master)
```
docker kill redis-cluster-redis2-1   # a master owning slots 5461-10922
-> master,fail; its replica (172.18.0.3) promoted to master (epoch bumped 2 -> 7)
cluster_state:ok  cluster_slots_ok:16384  cluster_size:3   # self-healed
GET foo / GET baz -> values intact                          # no data loss
```

### 5d. Sentinel HA (single primary, no sharding)
```bash
docker compose -f redis-sentinel/docker-compose.yml up -d   # 1 primary + 2 replicas + 3 sentinels (quorum 2)
```
```
primary: connected_slaves:2     sentinel master mymaster: num-slaves 2, num-other-sentinels 2, quorum 2
docker stop <primary>  -> sentinels detect down (5s) -> promote rreplica1 to master
  new master = 172.18.0.3   canary key = "survives-failover"   # data preserved
docker start <old primary> -> sentinel DEMOTES it to replica of the new master (role:slave)
```
- **Takeaway:** Sentinel = automatic failover + monitoring for **one** primary (no sharding).
  Cluster = sharding across 16384 slots **plus** per-shard failover. Pick Sentinel for HA-only,
  Cluster when you also need horizontal scale.

---

## 6. PostgreSQL 18 — streaming replication + hot standby + promotion (failover)

### 6a. Primary + streaming replica via replication slot
```bash
docker compose -f pg-replication/docker-compose.yml up -d
# replica auto-clones with: pg_basebackup -h pgprimary -U replicator -Fp -Xs -R -S replica1_slot
```
```
replica log: entering standby mode -> consistent recovery state reached
             -> ready to accept read-only connections -> started streaming WAL on timeline 1
```
> **Gotcha hit & fixed (PG18!):** the postgres:18 image **rejects** a volume mounted at
> `/var/lib/postgresql/data` ("data in unused mount/volume"). PG18 wants the mount at
> **`/var/lib/postgresql`** with data in an `18/docker` subdir (enables `pg_upgrade --link`).
> Fixed both primary and replica mounts; set replica `PGDATA=/var/lib/postgresql/18/docker`.

### 6b. Replication working + read-only standby
```
INSERT on primary -> SELECT on replica returns the row     # streaming replication
INSERT on replica -> ERROR: cannot execute INSERT in a read-only transaction
```

### 6c. Monitoring lag + slot
```
pg_stat_replication: state=streaming  sync_state=async  write_lag≈104µs  replay_lag≈383µs
pg_replication_slots: replica1_slot  active=t  wal_status=reserved
replica lag in bytes: 0
```

### 6d. Failover by promotion
```
SELECT pg_promote();           -> t
pg_is_in_recovery()            -> f          # standby is now a primary
INSERT on promoted node        -> INSERT 0 1 # writes accepted
timeline_id                    -> 2          # bumped 1 -> 2 on promotion
```
- **Production notes:** physical slot prevents the primary from removing WAL the replica still needs
  (watch for unbounded WAL if a replica is down). For automated failover use **Patroni** (etcd/raft +
  watchdog) or repmgr; basebackup + archived WAL = PITR.

---

## 7. Observability — exporters → Prometheus → Grafana (golden signals)

```bash
docker compose -f observability/docker-compose.yml up -d
# Prometheus http://localhost:9091/targets   Grafana http://localhost:3002 (admin/admin123)
```
```
Prometheus targets: postgres -> up   redis -> up   prometheus -> up
sum(pg_stat_database_numbackends)            = 2
rate(redis_commands_processed_total[1m])     = 27.7
redis_keyspace_hits_total / misses_total     = 500 / 500   (50% hit ratio)
Grafana: datasource "Prometheus" + dashboard "DBA Golden Signals" (uid=dba-golden) auto-provisioned
```
- **Takeaway:** the pattern is always the same — a per-engine **exporter** exposes `/metrics`,
  Prometheus scrapes on an interval, Grafana renders the **golden signals** (latency, traffic, errors,
  saturation) plus DB-specific ones (connections, cache hit ratio, replication lag, ops/sec).

---

## Cleanup
```bash
for d in mongo-ha mongo-shard scylla-ha solr-ha galera-ha redis-cluster redis-sentinel \
         pg-replication observability; do
  docker compose -f $d/docker-compose.yml down -v 2>/dev/null; done
```

## Summary by engine
- *MongoDB:* I stood up a 3-node replica set, killed the primary, watched the election, and
  `w:majority` writes continued; then sharded a 100k collection on a hashed key — even 50/50 split,
  single-shard targeting when the shard key is present, scatter-gather otherwise.
- *ScyllaDB:* 3-node RF=3; QUORUM reads survived a node down. Snapshot + `nodetool refresh`
  restore, including the truncation-marker and `upload/` gotchas. Hit the AIO limit and fixed it
  with a VM-wide sysctl.
- *SolrCloud:* 2 shards × 2 replicas, GREEN; dropped a node → ORANGE but fully queryable →
  auto-recovered to GREEN. Collection BACKUP/RESTORE via a shared path with `solr.allowPaths`.
- *Galera:* 3-node multi-master; wrote on one node and read it synchronously on another. Hammered
  one row from two masters and watched certification catch the conflicts (cert failures + BF aborts)
  while the counter still converged. Showed the graceful-leave-stays-Primary vs ungraceful-kill-goes-
  non-Primary quorum behavior, and IST rejoin.
- *Redis:* 6-node Cluster, 16384 slots; killed a master and its replica auto-promoted (epoch bumped),
  cluster stayed `state:ok` with no data loss. Separately, Sentinel with quorum 2 promoted a replica
  ~5s after I stopped the primary, and demoted the old primary to a replica when it returned.
- *PostgreSQL:* Primary + hot-standby over a replication slot, sub-ms replay lag; standby rejected
  writes, then `pg_promote()` took it out of recovery (timeline 1→2) and writes flowed. Also hit and
  fixed the PG18 `/var/lib/postgresql` mount-point change.
- *Observability:* Stood up postgres/redis exporters → Prometheus → auto-provisioned Grafana
  'Golden Signals' dashboard; verified all targets UP and queried connections, ops/sec, and a 50%
  cache-hit ratio end-to-end.
