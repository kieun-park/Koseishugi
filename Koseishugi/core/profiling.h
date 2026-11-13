#pragma once

#include <cstdint>
#include <atomic>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace core {

struct ProfilerConfig {
    uint64_t perf_event_config = 0x20d1ULL;
    int sampling_interval = 1000;
    int duration_ms = 30000;
    int ring_pages = 256; // Per-CPU perf data pages; must be a power of two.
    std::string proc_hist_path = "/proc/pebs_page_hist";
    std::string output_dir = "logs";
    std::string cgroup_resolve = "auto";
    bool histogram_logging = false;
};

struct ProfilerTarget {
    std::string service;        // docker container name
    std::string container_id;   // docker container ID (full)
    int init_pid = -1;          // container init pid (host PID namespace)
    std::string cgroup_path;    // full path under /sys/fs/cgroup
};

struct ProfilerResult {
    bool ok = false;
    std::string used_cgpath;
    std::string note;
    ProfilerTarget target;
    std::string log_path;
    uint64_t records      = 0;   // total PEBS phys-addr samples captured
    int pages_total       = 0;   // unique PFNs observed
    uint64_t lost_events  = 0;   // lost samples reported by perf
    std::unordered_map<uint64_t, uint64_t> hist;
};

class Profiler {
public:
    explicit Profiler(ProfilerConfig cfg);
    bool KernelReady() const;
    std::string ResolveCgroupPath(const std::string& service) const;
    ProfilerResult RunOnceForService(const std::string& service_name,
                                  const std::string& log_prefix = "",
                                  const std::atomic<bool>* stop = nullptr);
    bool ResolveTargetByService(const std::string& service_name,
                                ProfilerTarget& out_target,
                                std::string& note) const;

private:
    ProfilerConfig cfg_;
    using Histogram = std::unordered_map<uint64_t, uint64_t>;

    static bool GetContainerIdAndPid(const std::string& service_name,
                                     std::string& cid,
                                     int& pid,
                                     std::string& note);

    static bool GetCgroupPathFromPid(int pid, std::string& out_full_path,
                                     std::string& note);

    static bool PathExists(const std::string& p);
    static std::string SystemdDockerScopePath(const std::string& full_container_id);


};

} // namespace core
