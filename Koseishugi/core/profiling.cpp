
#include "core/policy.h"
#include <cctype>
#include <cstring>
#include <set>
#include <sstream>
#include <string>

namespace core {
inline std::vector<int> ParseCpuList(std::string text) {
    text.erase(std::remove_if(text.begin(), text.end(), [](unsigned char c) { return std::isspace(c); }), text.end());
    if (text.empty() || text.back() == ',') throw std::invalid_argument("empty or invalid CPU list");
    std::set<int> cpus;
    std::istringstream in(text);
    std::string item;
    auto cpu_number = [](const std::string& value) {
        if (value.empty() || value.find_first_not_of("0123456789") != std::string::npos)
            throw std::invalid_argument("invalid CPU number");
        const int n = std::stoi(value);
        if (n > 65535) throw std::invalid_argument("CPU number out of range");
        return n;
    };
    while (std::getline(in, item, ',')) {
        const auto dash = item.find('-');
        const int first = cpu_number(item.substr(0, dash));
        const int last = dash == std::string::npos ? first : cpu_number(item.substr(dash + 1));
        if (last < first) throw std::invalid_argument("descending CPU range");
        for (int n = first; n <= last; ++n) cpus.insert(n);
    }
    return {cpus.begin(), cpus.end()};
}
struct SampleHeader { std::uint32_t type; std::uint16_t misc, size; };
static_assert(sizeof(SampleHeader) == 8, "perf record header layout");
constexpr std::uint32_t kRecordLost = 2, kRecordSample = 9, kRecordLostSamples = 13;

inline void ReadRing(const std::uint8_t* data, std::size_t size, std::uint64_t offset,
                     void* destination, std::size_t count) {
    const auto start = static_cast<std::size_t>(offset & (size - 1));
    const auto first = std::min(count, size - start);
    std::memcpy(destination, data + start, first);
    if (first != count) std::memcpy(static_cast<std::uint8_t*>(destination) + first, data, count - first);
}
inline bool DrainSamples(const std::uint8_t* data, std::size_t size,
                         std::uint64_t head, std::uint64_t& tail, std::uint64_t page_size,
                         Histogram& histogram, std::uint64_t& records, std::uint64_t& lost,
                         bool require_complete = false) {
    if (!size || (size & (size - 1)) || !page_size || head < tail || head - tail > size) return false;
    while (head - tail >= sizeof(SampleHeader)) {
        SampleHeader header;
        ReadRing(data, size, tail, &header, sizeof(header));
        if (header.size < sizeof(header) || header.size > size) return false;
        if (header.size > head - tail) break;
        if (header.type == kRecordSample) {
            if (header.size < sizeof(header) + sizeof(std::uint64_t)) return false;
            std::uint64_t address = 0;
            ReadRing(data, size, tail + sizeof(header), &address, sizeof(address));
            if (address) { ++histogram[address / page_size]; ++records; }
        } else if (header.type == kRecordLost || header.type == kRecordLostSamples) {
            const auto skip = header.type == kRecordLost ? sizeof(std::uint64_t) : 0;
            if (header.size < sizeof(header) + skip + sizeof(std::uint64_t)) return false;
            std::uint64_t count = 0;
            ReadRing(data, size, tail + sizeof(header) + skip, &count, sizeof(count));
            lost += count;
        }
        tail += header.size;
    }
    return !require_complete || tail == head;
}
} // namespace core

#include "core/profiling.h"


#include "pkg/util.h"
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <memory>
#include <iterator>
#include <sstream>
#include <thread>
#include <fcntl.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <linux/perf_event.h>

namespace core {
static_assert(PERF_RECORD_SAMPLE == kRecordSample && PERF_RECORD_LOST == kRecordLost &&
              PERF_RECORD_LOST_SAMPLES == kRecordLostSamples, "perf ABI record types");
Profiler::Profiler(ProfilerConfig cfg) : cfg_(std::move(cfg)) {}
bool Profiler::KernelReady() const {
    KernelAbi info;
    std::string note;
    return ReadKernelAbi(cfg_.proc_hist_path, info, note);
}
std::string Profiler::ResolveCgroupPath(const std::string& service) const {
    ProfilerTarget t;
    std::string note;
    if (!ResolveTargetByService(service, t, note))
        return "<unresolved>" + note;
    return t.cgroup_path.empty() ? "<empty>" : t.cgroup_path;
}

bool Profiler::GetContainerIdAndPid(const std::string& service_name,
                               std::string& cid, int& pid,
                               std::string& note) {
    std::string ps = util::run_cmd("docker ps --format '{{.ID}}|{{.Names}}'");
    if (ps.empty()) {
        note = "docker ps empty (is Docker running / permission ok?)";
        return false;
    }

    std::istringstream iss(ps);
    std::string line, found_id;
    while (std::getline(iss, line)) {
        line = util::trim(line);
        if (line.empty()) continue;
        auto bar = line.find('|');
        if (bar == std::string::npos) continue;
        if (util::trim(line.substr(bar + 1)) == service_name) {
            found_id = util::trim(line.substr(0, bar));
            break;
        }
    }
    if (found_id.empty()) {
        note = "service not found in docker ps: " + service_name;
        return false;
    }

    std::string full_id = util::trim(util::run_cmd(
        "docker inspect -f '{{.Id}}' " + found_id + " 2>/dev/null"));
    if (full_id.empty()) full_id = found_id;

    std::string pid_str = util::trim(util::run_cmd(
        "docker inspect -f '{{.State.Pid}}' " + found_id + " 2>/dev/null"));
    if (pid_str.empty()) {
        note = "docker inspect pid failed for: " + found_id;
        return false;
    }
    int p = -1;
    try { p = std::stoi(pid_str); } catch (...) { p = -1; }
    if (p <= 0) {
        note = "invalid container pid: " + pid_str;
        return false;
    }

    cid = full_id;
    pid = p;
    return true;
}

bool Profiler::PathExists(const std::string& p) {
    return ::access(p.c_str(), F_OK) == 0;
}

std::string Profiler::SystemdDockerScopePath(const std::string& full_container_id) {
    return "/sys/fs/cgroup/system.slice/docker-" + full_container_id + ".scope";
}

bool Profiler::GetCgroupPathFromPid(int pid, std::string& out_full_path,
                               std::string& note) {
    std::string cg;
    if (!util::read_file("/proc/" + std::to_string(pid) + "/cgroup", cg)) {
        note = "read /proc/<pid>/cgroup failed";
        return false;
    }

    std::istringstream iss(cg);
    std::string line, v2_path;
    while (std::getline(iss, line)) {
        line = util::trim(line);
        if (line.rfind("0::", 0) == 0) {
            v2_path = util::trim(line.substr(3));
            break;
        }
    }
    if (v2_path.empty()) {
        note = "cgroup v2 entry (0::) not found";
        return false;
    }

    out_full_path = "/sys/fs/cgroup" +
                    (v2_path[0] == '/' ? v2_path : "/" + v2_path);
    return true;
}

bool Profiler::ResolveTargetByService(const std::string& service_name,
                                ProfilerTarget& out_target,
                                std::string& note) const {
    std::string cid;
    int pid = -1;
    if (!GetContainerIdAndPid(service_name, cid, pid, note)) return false;

    std::string cg_path;
    const std::string mode = cfg_.cgroup_resolve;
    bool ok = false;

    if (mode == "systemd" || mode == "auto") {
        std::string p = SystemdDockerScopePath(cid);
        if (PathExists(p)) {
            cg_path = p;
            ok = true;
        } else if (mode == "systemd") {
            note = "systemd cgroup path not found: " + p;
            return false;
        }
    }
    if (!ok && (mode == "proc" || mode == "auto")) {
        if (!GetCgroupPathFromPid(pid, cg_path, note)) return false;
        ok = true;
    }
    if (!ok) {
        note = "failed to resolve cgroup path";
        return false;
    }

    out_target.service      = service_name;
    out_target.container_id = cid;
    out_target.init_pid     = pid;
    out_target.cgroup_path  = cg_path;
    return true;
}


namespace {
struct FileDescriptor {
    int fd;
    explicit FileDescriptor(int value) : fd(value) {}
    ~FileDescriptor() { if (fd >= 0) ::close(fd); }
    FileDescriptor(const FileDescriptor&) = delete;
    FileDescriptor& operator=(const FileDescriptor&) = delete;
};
struct PerfRing {
    int fd = -1;
    void* mapping = MAP_FAILED;
    std::size_t mapping_size = 0;
    std::uint64_t offset = 0, size = 0;
    ~PerfRing() {
        if (fd >= 0) ::ioctl(fd, PERF_EVENT_IOC_DISABLE, 0);
        if (mapping != MAP_FAILED) ::munmap(mapping, mapping_size);
        if (fd >= 0) ::close(fd);
    }
    bool Drain(Histogram& hist, std::uint64_t& records, std::uint64_t& lost, std::uint64_t page_size, bool final = false) {
        auto* meta = static_cast<perf_event_mmap_page*>(mapping);
        const auto head = __atomic_load_n(&meta->data_head, __ATOMIC_ACQUIRE);
        std::uint64_t tail = meta->data_tail;
        const bool ok = DrainSamples(static_cast<const std::uint8_t*>(mapping) + offset,
                                     size, head, tail, page_size, hist, records, lost, final);
        __atomic_store_n(&meta->data_tail, tail, __ATOMIC_RELEASE);
        return ok;
    }
};
std::string error_text(const std::string& operation) {
    const int saved = errno;
    return operation + ": " + std::strerror(saved) + " (errno=" + std::to_string(saved) + ")";
}
}

ProfilerResult Profiler::RunOnceForService(const std::string& service_name,
                                          const std::string& log_prefix,
                                          const std::atomic<bool>* stop) {
    ProfilerResult result;
    if (stop && stop->load(std::memory_order_relaxed)) { result.note = "sampling cancelled"; return result; }
    if (!ResolveTargetByService(service_name, result.target, result.note)) return result;
    result.used_cgpath = result.target.cgroup_path;
    const auto cancelled = [&] { return stop && stop->load(std::memory_order_relaxed); };
    if (cancelled()) { result.note = "sampling cancelled"; return result; }
    FileDescriptor cgroup(::open(result.used_cgpath.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC));
    if (cgroup.fd < 0) { result.note = error_text("open cgroup"); return result; }

    std::vector<int> cpus;
    try {
        std::string online, allowed;
        if (!util::read_file("/sys/devices/system/cpu/online", online)) {
            result.note = "cannot read online CPUs"; return result;
        }
        const auto online_cpus = ParseCpuList(online);
        if (util::read_file(result.used_cgpath + "/cpuset.cpus.effective", allowed) && !util::trim(allowed).empty()) {
            const auto allowed_cpus = ParseCpuList(allowed);
            std::set_intersection(online_cpus.begin(), online_cpus.end(), allowed_cpus.begin(), allowed_cpus.end(),
                                  std::back_inserter(cpus));
        } else cpus = online_cpus;
    } catch (const std::exception& e) { result.note = e.what(); return result; }
    if (cpus.empty()) { result.note = "no online CPU in target cpuset"; return result; }
    const long page_size = ::sysconf(_SC_PAGESIZE);
    if (page_size <= 0 || cfg_.ring_pages <= 0 || (cfg_.ring_pages & (cfg_.ring_pages - 1))) {
        result.note = "invalid perf ring geometry"; return result;
    }
    const std::size_t mapping_size = (static_cast<std::size_t>(cfg_.ring_pages) + 1) * page_size;
    std::vector<std::unique_ptr<PerfRing>> rings;
    rings.reserve(cpus.size());
    for (int cpu : cpus) {
        if (cancelled()) { result.note = "sampling cancelled"; return result; }
        auto ring = std::make_unique<PerfRing>();
        perf_event_attr attr{};
        attr.type = PERF_TYPE_RAW;
        attr.size = sizeof(attr);
        attr.config = cfg_.perf_event_config;
        attr.sample_period = cfg_.sampling_interval;
        attr.sample_type = PERF_SAMPLE_PHYS_ADDR;
        attr.precise_ip = 1;
        attr.exclude_kernel = 1;
        attr.exclude_hv = 1;
        attr.disabled = 1;
        ring->fd = static_cast<int>(::syscall(SYS_perf_event_open, &attr, cgroup.fd, cpu, -1,
                                              PERF_FLAG_PID_CGROUP | PERF_FLAG_FD_CLOEXEC));
        if (ring->fd < 0) { result.note = error_text("perf_event_open cpu=" + std::to_string(cpu)); return result; }
        ring->mapping_size = mapping_size;
        ring->mapping = ::mmap(nullptr, mapping_size, PROT_READ | PROT_WRITE, MAP_SHARED, ring->fd, 0);
        if (ring->mapping == MAP_FAILED) { result.note = error_text("mmap perf ring"); return result; }
        const auto* meta = static_cast<const perf_event_mmap_page*>(ring->mapping);
        ring->offset = meta->data_offset;
        ring->size = meta->data_size;
        if (ring->offset < static_cast<std::uint64_t>(page_size) || ring->offset > mapping_size ||
            !ring->size || (ring->size & (ring->size - 1)) || ring->size > mapping_size - ring->offset) {
            result.note = "kernel returned invalid perf ring geometry"; return result;
        }
        rings.push_back(std::move(ring));
    }
    for (const auto& ring : rings) {
        if (::ioctl(ring->fd, PERF_EVENT_IOC_RESET, 0) < 0 || ::ioctl(ring->fd, PERF_EVENT_IOC_ENABLE, 0) < 0) {
            result.note = error_text("enable PEBS event"); return result;
        }
    }
    Histogram hist;
    hist.reserve(16384);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(cfg_.duration_ms);
    while (!cancelled() && std::chrono::steady_clock::now() < deadline) {
        for (const auto& ring : rings) {
            if (!ring->Drain(hist, result.records, result.lost_events, page_size)) {
                result.note = "invalid perf ring record"; return result;
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    for (const auto& ring : rings) {
        if (::ioctl(ring->fd, PERF_EVENT_IOC_DISABLE, 0) < 0) {
            result.note = error_text("disable PEBS event"); return result;
        }
    }
    for (const auto& ring : rings) {
        if (!ring->Drain(hist, result.records, result.lost_events, page_size, true)) {
            result.note = "invalid final perf ring record"; return result;
        }
    }
    if (cancelled()) { result.note = "sampling cancelled"; return result; }
    result.hist = std::move(hist);
    result.pages_total = static_cast<int>(result.hist.size());
    result.ok = true;
    result.note = "ok; sampled_cpus=" + std::to_string(cpus.size());
    if (cfg_.histogram_logging) {
        try {
            if (!cfg_.output_dir.empty()) std::filesystem::create_directories(cfg_.output_dir);
            const auto stamp = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::system_clock::now().time_since_epoch()).count();
            std::string name = log_prefix.empty() ? service_name : log_prefix;
            for (auto& ch : name) if (!std::isalnum(static_cast<unsigned char>(ch)) && ch != '-' && ch != '_') ch = '_';
            const auto path = std::filesystem::path(cfg_.output_dir) / (name + "_pebs_" + std::to_string(stamp) + ".log");
            std::ofstream log(path);
            log << "service=" << service_name << "\ncgroup=" << result.used_cgpath
                << "\ncpus=" << cpus.size() << "\nperiod=" << cfg_.sampling_interval
                << "\nduration_ms=" << cfg_.duration_ms << "\nrecords=" << result.records
                << "\nlost_samples=" << result.lost_events << "\n";
            std::vector<std::pair<std::uint64_t, std::uint64_t>> all(result.hist.begin(), result.hist.end());
            std::sort(all.begin(), all.end(), [](const auto& a, const auto& b) {
                return a.second != b.second ? a.second > b.second : a.first < b.first;
            });
            for (const auto& item : all) log << item.first << " " << item.second << "\n";
            if (log) result.log_path = path.string();
            else result.note += "; histogram log write failed";
        } catch (const std::exception& e) { result.note += std::string("; log error: ") + e.what(); }
    }
    return result;
}
} // namespace core
