# Evaluation harness

Linux scripts for the DeathStarBench SocialNetwork and HotelReservation workloads.
Each RPS point restores a prepared database snapshot, starts the selected placement,
runs a warm-up phase, and records a measurement phase. The userspace agent is
started separately; these scripts do not select or launch it automatically.

## Requirements

- A Linux host with the intended kernel and memory tiers; see [kernel integration](../README.md).
- Bash, Docker Engine with Compose v2, Python 3, `numactl`, `rsync`, `jq`, `curl`,
  `iproute2` (`ip`, `ss`), `util-linux` (`nsenter`), and GNU core utilities.
- A prepared DeathStarBench checkout, its workload dependencies and datasets,
  and a built **wrk2** binary (the implementation supporting `-R` and `-D exp`).
- Root access for NUMA settings, memory hotplug, container control, and counters.
  Distributed runs also need SSH and noninteractive sudo on Server B.

The default topology is node 0 = service DRAM, node 1 = client DRAM/CPUs,
node 2 = CXL memory. Check `numactl --hardware` and set the node variables for
your machine. Service CPUs default to the selected local CPU node's CPU list;
Server B defaults to its node 0 CPU list. Override `SVC_CPUSET` locally and
`REMOTE_SVC_CPUSET` through the harness for Server B where necessary.

Run on dedicated experiment hosts. The harness stops/recreates containers,
replaces database volume contents from snapshots, and changes kernel settings.
Hotel and remote prerequisite helpers also disable swap, set the CPU governor,
and change the firewall FORWARD policy. Cleanup does not restore every host
setting; record the initial state. `--setup` deliberately leaves the stack and
memory settings active. The placement tools rewrite workload configuration files.

## Prepare the workload

Run these examples from the repository root and replace `/path/to/...` values.
The Compose files are templates for a **DeathStarBench workload directory**:
their relative build/config/volume paths do not resolve from this repository.

```bash
# HotelReservation; back up an existing Compose file before replacing it.
cp run/hotel_docker-compose.yml /path/to/DeathStarBench/hotelReservation/docker-compose.yml
# SocialNetwork
cp run/social_docker-compose.yml /path/to/DeathStarBench/socialNetwork/docker-compose.yml
chmod +x run/*.sh Koseishugi/start_agent.sh
```

Build the corresponding application images in that checkout and initialize its
dataset before taking a snapshot. HotelReservation includes review and attractions
services, so the checkout and images must provide those entrypoints. SocialNetwork
requires the graph and post data used by your experiment. The optional
`INIT_DATASET=on` path invokes that checkout's `scripts/init_social_graph.py`;
check its flags and dataset availability before using it.

Record the DeathStarBench commit, workload/data preparation, kernel commit/config,
resolved image digests, and all environment overrides with each experiment. Several
Compose images use mutable tags, including `latest`; this repository does not
supply an immutable image manifest or prepared database snapshots. Script
defaults alone are therefore not a complete reproduction of experiment results.

Bring up the workload using Compose in its own directory, complete data loading,
then capture the stopped database state:

```bash
sudo env DSB_DIR=/path/to/DeathStarBench/hotelReservation \
  DB_SNAPSHOT_DIR=/path/to/snapshots/hotel \
  bash run/hotel_run_eval.sh --snapshot

sudo env DSB_DIR=/path/to/DeathStarBench/socialNetwork \
  DB_SNAPSHOT_DIR=/path/to/snapshots/social \
  bash run/social_run_eval.sh --snapshot
```

Snapshot capture stops the local stack. Prepare snapshots before splitting the
services between hosts, then copy the relevant snapshots to Server B with
ownership preserved. Keep the Compose project name stable. Restoration expects
ordinary local Docker volumes named `<project>_<volume>`; missing required
snapshots stop the run. `DB_SNAPSHOT_ENABLED=off` skips restoration and lets writes
accumulate across points.

## Single-host run

Set the frontend URL explicitly. The address used by the client affects the
network path, so use the same address and routing across comparisons.

```bash
sudo env DSB_DIR=/path/to/DeathStarBench/hotelReservation \
  DB_SNAPSHOT_DIR=/path/to/snapshots/hotel \
  WRK_BIN=/path/to/DeathStarBench/wrk2/wrk \
  TARGET_URL=http://YOUR_FRONTEND_IP:5000 \
  RPS_START=2000 RPS_END=2000 RPS_STEP=200 \
  bash run/hotel_run_eval.sh
```

For SocialNetwork, use `social_run_eval.sh`, the `socialNetwork` checkout,
the social snapshot, and port 8080. The examples use script defaults for the
remaining settings; choose values for the intended experiment before running.

For Koseishugi, run the agent on the host whose service memory is being
managed, using the intended configuration in a separate terminal:

```bash
sudo bash Koseishugi/start_agent.sh /absolute/path/to/config.yaml
```

## Distributed run

Server A drives wrk2 and hosts the frontend and remaining services. Server B hosts
the selected services and is where tiering settings and memory counters apply.
Copy this repository's `run/` directory and the prepared workload checkout to both
hosts. Set these variables explicitly for placement and harness commands:

| Variable | Meaning |
| --- | --- |
| `REMOTE_B` | SSH destination, e.g. `user@server-b` |
| `REMOTE_AGENT` | Absolute Server B path to `run/remote_b.sh` |
| `HOST_A_IP`, `HOST_B_IP` | Routable addresses used by the services |
| `REMOTE_DSB_DIR` | Server B workload path (defaults to local `DSB_DIR` in the harness) |
| `REMOTE_DB_SNAPSHOT_DIR` | Server B snapshot path (defaults to local `DB_SNAPSHOT_DIR`) |
| `DIST_MODE=on` | Enable distributed evaluation |

Hotel placement: `bash run/placement.sh top5mc` places five services and their
three memcached instances on B; `top5` and `top3set` provide alternative splits.
Use `DSB_DIR`/`REMOTE_DSB_DIR` for its workload paths. The generated
`run/placement.env` is read by `hotel_run_eval.sh`.

Social placement: `bash run/social_placement.sh top7` also requires
`DSB_DIR_A`, `DSB_DIR_B`, `HOST_B_IP2`, `IP_ALIAS_DEV` (on B), and
`REMOTE_DB_SNAPSHOT_DIR`. `IP_ALIAS_PREFIX` defaults to 24. The second B address
allows two services to retain port 9090. The tool writes
`run/social_placement.env` and a context wrapper `rbs` next to `REMOTE_AGENT`.
It also configures that address on B. Paths passed to placement tools should not
contain shell quotes; review generated files before starting the stack.

Pass the same host/path settings to the evaluation harness with `DIST_MODE=on`.
Both harnesses offer `--setup` to start and verify the placement before a sweep.
Hotel additionally offers `--teardown`; stop each Compose project explicitly after
a SocialNetwork setup. Run `social_placement.sh check` only after both stacks are
up. Store the environment overrides with the logs; the generated placement files
contain only part of the configuration.

## Important controls

| Setting | Effect |
| --- | --- |
| `RPS_START`, `RPS_END`, `RPS_STEP` | Load sweep; SocialNetwork also accepts `RPS_LIST` |
| `WARMUP_DURATION_S`, `MEASURE_DURATION_S` | Phase durations |
| `WRK_T`, `WRK_C`, `WRK_SCRIPT` | wrk2 threads, connections, and Lua workload |
| `DOCKER_CPU_NODE`, `SVCMEM_NODE`, `CLIENT_CPU_NODE`, `CLIENT_MEM_NODE` | NUMA placement |
| `MEM_SIZE_GB` | Target node 0 size; 0 leaves physical capacity unchanged |
| `MEM_SIZE_GB_NODE2` | Server B node 2 target in distributed mode |
| `MEM_HOLDER_GB` | Additional pinned memory pressure; 0 disables it |
| `NUMA_BALANCING`, `DEMOTION_ENABLED` | Kernel tiering controls |
| `HTMM_ENABLE` | MEMTIS-specific path, requiring a separate compatible kernel |
| `LOG_DIR`, `APP` | Output directory and experiment label |

`dram_limit.sh` offlines physical memory blocks and may not reach the requested
capacity if pages cannot migrate. Check the reported capacity, not only the target.
Its `--restore --node N` onlines **all** offline blocks on that node, including
blocks offlined before the run; it is not a saved-state rollback.

```bash
sudo bash run/dram_limit.sh --target-size-gb 16 --node 0
sudo bash run/dram_limit.sh --restore --node 0
```

`numa_bind.sh` applies affinity to running containers in the current Compose
project. `sample_services.sh` records per-service receive queues and memory; its
`--summary` and `--coverage` modes analyze the generated CSV files.

## Output and validation

Harness logs default to `run/logs/` and use:

```text
<APP>_<WRK_SCRIPT_TYPE>_rps<RPS>_<YYYYMMDD_HHMMSS>.run.log
```

They include wrk2 output and memory/NUMA statistics. Preserve raw logs and inspect
request errors and achieved throughput before interpreting latency. A failed wrk2
process stops the run, but successful exit alone does not establish a valid load.

Shell syntax can be checked without starting containers or workloads:

```bash
for script in run/*.sh Koseishugi/start_agent.sh; do bash -n "$script" || exit; done
```

Syntax checks do not validate Docker networking, kernel integration, memory
hotplug, service readiness, or benchmark results; those require the target Linux
system and prepared datasets.
