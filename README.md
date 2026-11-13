# Koseishugi

Linux userspace agent for CXL tiered memory management. It uses TCP receive-queue backlog to select a container, samples its memory accesses through PEBS, and submits selected PFNs to kernel migration gates.

## Requirements

Native x86-64 Linux v6.12, an Intel CPU supporting the configured precise load event and physical-address sampling, Docker with cgroup v2, and separate service network namespaces. Host DRAM/CXL NUMA tiers and the underlying tiering policy must be configured separately.

The agent requires root, a C++17 compiler, GNU coreutils (`timeout`), util-linux (`nsenter`) and iproute2 (`ss`). The kernel hooks target base pages; disable transparent huge pages. The 262144-entry buffer represents 1 GiB at 4 KiB/page and must be smaller than the fast tier.

## Kernel

Apply these patches to an unmodified upstream Linux v6.12 checkout:

```bash
git apply --check /path/to/patch/pebs-page-hist.patch /path/to/patch/mm-tiering-hooks.patch
git apply /path/to/patch/pebs-page-hist.patch /path/to/patch/mm-tiering-hooks.patch
make olddefconfig
make -j"$(nproc)"
```

Install and boot the resulting kernel before running the agent. Enable procfs, NUMA balancing, migration and the platform's memory-tiering support. `sched-fair-wmark.patch` is optional promotion-headroom tuning; use identical settings in comparison runs. `patch/paddr.c` contains optional DAMON integration for the same v6.12 base.

The private native-x86-64 syscalls are 463 (merge), 464 (clear) and 465 (age). The agent verifies the `Koseishugi_abi=1` marker in `/proc/pebs_page_hist` before calling them. These numbers must not be used on other kernels. Merge refreshes an LRU buffer and enables gating; aging and clear disable both promotion and demotion gates. PFNs are not tracked across migration, freeing or reuse.

## Agent

Edit `Koseishugi/config.yaml`, then run from the repository root:

```bash
sudo bash Koseishugi/start_agent.sh
sudo bash Koseishugi/start_agent.sh /absolute/path/to/config.yaml
```

The launcher builds from source each time. To compile and validate configuration without root or kernel operations:

```bash
cd Koseishugi
mkdir -p bin
c++ -std=c++17 -O2 -Wall -Wextra -pthread -I. app/*.cpp core/*.cpp pkg/*.cpp -o bin/agent
./bin/agent --check-config config.yaml
```

Check the interface, service exclusions, PMU event and sampling period for the target workload. Raw event encodings depend on the CPU. Sampling covers the selected cgroup on its allowed online CPUs; ring memory scales with CPU count. The default coverage is 80%, queue threshold 1 KiB, and optional cooldown 0. The per-update page limit must be below kernel capacity.

Run one agent per host. Ctrl+C or SIGTERM stops sampling and clears the gates. Application-only queues, kernel-bypass networking and shared network namespaces are not attributed to services. CPU/cpuset changes take effect in the next sampling window.

## Workloads

See [run/README.md](run/README.md) for workload preparation and evaluation. Images, datasets and prepared database snapshots are not included. The scripts modify host/container settings and require a dedicated experiment host.

The agent has been cross-compiled for Linux and its core logic checked on the preparation host. Kernel patches were checked against upstream v6.12. Full kernel build/boot, concurrency and CXL performance validation remain necessary on the target server. Exclude generated `bin/`, build outputs and experiment logs when publishing sources.
