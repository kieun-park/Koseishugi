#include "core/monitor.h"
#include <cmath>
#include <fstream>
#include <set>
#include <sstream>
#include <stdexcept>
namespace core {
namespace {
std::string trim(const std::string& s) {
    const auto first = s.find_first_not_of(" \t\r\n");
    return first == std::string::npos ? "" : s.substr(first, s.find_last_not_of(" \t\r\n") - first + 1);
}
std::string unquote(std::string s) {
    if (s.size() >= 2 && ((s.front() == '"' && s.back() == '"') || (s.front() == '\'' && s.back() == '\'')))
        s = s.substr(1, s.size() - 2);
    return s;
}
int integer(const std::string& s) {
    std::size_t n = 0; const int value = std::stoi(s, &n);
    if (n != s.size()) throw std::invalid_argument("invalid integer");
    return value;
}
double number(const std::string& s) {
    std::size_t n = 0; const double value = std::stod(s, &n);
    if (n != s.size() || !std::isfinite(value)) throw std::invalid_argument("invalid finite number");
    return value;
}
}
bool ReadConfig(const std::string& path, AgentConfig& cfg, std::string& error) {
    std::ifstream in(path);
    if (!in) { error = "cannot open " + path; return false; }
    std::set<std::string> seen;
    std::string line;
    int line_number = 0;
    try {
        while (std::getline(in, line)) {
            ++line_number;
            bool quoted = false; char quote = 0;
            for (std::size_t i = 0; i < line.size(); ++i) {
                if (!quoted && (line[i] == '\'' || line[i] == '"')) { quoted = true; quote = line[i]; }
                else if (quoted && line[i] == quote) quoted = false;
                else if (!quoted && line[i] == '#') { line.resize(i); break; }
            }
            line = trim(line);
            if (line.empty()) continue;
            const auto colon = line.find(':');
            if (colon == std::string::npos) throw std::invalid_argument("expected key: value");
            auto key = trim(line.substr(0, colon));
            const auto val = unquote(trim(line.substr(colon + 1)));
            if (key == "p2_pfn_percentile") key = "p3_pfn_percentile";
            if (key == "p2_pfn_hist_max") key = "p3_pfn_hist_max";
            if (!seen.insert(key).second) throw std::invalid_argument("duplicate key " + key);
            if (key == "agent_tick_ms") cfg.tick_ms = integer(val);
            else if (key == "network_interface") cfg.netdev_iface = val;
            else if (key == "p0_burst_threshold_kib") cfg.p0_burst_threshold_kib = number(val);
            else if (key == "p1_recvq_threshold_kib") cfg.pressure_threshold_kib = number(val);
            else if (key == "experiment_tag") cfg.title = val;
            else if (key == "p2_sample_period") cfg.p2_sampling_interval = integer(val);
            else if (key == "p2_sampling_window_ms") cfg.p2_duration_ms = integer(val);
            else if (key == "p2_histogram_path") cfg.p2_proc_hist_path = val;
            else if (key == "p2_output_dir") cfg.p2_output_dir = val;
            else if (key == "p2_cgroup_resolve") cfg.p2_cgroup_resolve = val;
            else if (key == "p2_cooldown_ms") cfg.p2_cooldown_ms = integer(val);
            else if (key == "p2_ring_pages") cfg.p2_ring_pages = integer(val);
            else if (key == "p3_pfn_percentile") cfg.p3_pfn_percentile = integer(val);
            else if (key == "p3_pfn_hist_max") cfg.p3_pfn_hist_max = integer(val);
            else if (key == "p0_idle_threshold_ticks") cfg.p0_idle_threshold_ticks = integer(val);
            else if (key == "p0_idle_trim_pct") cfg.p0_idle_trim_pct = integer(val);
            else if (key == "histogram_logging") {
                if (val != "true" && val != "false") throw std::invalid_argument("histogram_logging must be true or false");
                cfg.histogram_logging = val == "true";
            } else if (key == "p2_perf_event_config") {
                std::size_t n = 0;
                if (val.empty() || val.front() == '-') throw std::invalid_argument("invalid perf event");
                cfg.p2_perf_event_config = std::stoull(val, &n, 0);
                if (n != val.size()) throw std::invalid_argument("invalid perf event");
            } else if (key == "p1_exclude_services") {
                if (val.size() < 2 || val.front() != '[' || val.back() != ']')
                    throw std::invalid_argument("p1_exclude_services must be an inline list");
                cfg.p1_blacklist.clear();
                std::istringstream items(val.substr(1, val.size() - 2));
                std::string item;
                while (std::getline(items, item, ',')) {
                    item = unquote(trim(item));
                    if (!item.empty()) cfg.p1_blacklist.push_back(item);
                }
            } else throw std::invalid_argument("unknown key " + key);
        }
        if (!seen.count("agent_tick_ms") || !seen.count("network_interface") || !seen.count("p0_burst_threshold_kib"))
            throw std::invalid_argument("agent_tick_ms, network_interface and p0_burst_threshold_kib are required");
        if (cfg.tick_ms <= 0 || cfg.netdev_iface.empty() || cfg.title.empty() ||
            cfg.p0_burst_threshold_kib < 0 || cfg.pressure_threshold_kib < 0 ||
            cfg.p2_sampling_interval <= 0 || cfg.p2_duration_ms <= 0 || cfg.p2_cooldown_ms < 0 ||
            cfg.p0_idle_threshold_ticks <= 0 || cfg.p0_idle_trim_pct < 1 || cfg.p0_idle_trim_pct > 100 ||
            cfg.p3_pfn_percentile < 1 || cfg.p3_pfn_percentile > 100 ||
            cfg.p3_pfn_hist_max <= 0 || cfg.p3_pfn_hist_max >= 262144 ||
            cfg.p2_ring_pages < 1 || cfg.p2_ring_pages > 4096 || (cfg.p2_ring_pages & (cfg.p2_ring_pages - 1)) ||
            cfg.p2_proc_hist_path != "/proc/pebs_page_hist" ||
            (cfg.p2_cgroup_resolve != "auto" && cfg.p2_cgroup_resolve != "systemd" && cfg.p2_cgroup_resolve != "proc"))
            throw std::invalid_argument("configuration value outside its supported range");
    } catch (const std::exception& e) {
        error = path + ":" + std::to_string(line_number) + ": " + e.what();
        return false;
    }
    return true;
}
} // namespace core

#include <atomic>
#include <chrono>
#include <csignal>
#include <iostream>
#include <thread>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>



#include "core/monitor.h"
#include "core/pressure.h"
#include "core/profiling.h"
#include "core/policy.h"
#include "pkg/tui.h"

static std::atomic<bool> stop_requested{false};
static void handle_signal(int) { stop_requested.store(true, std::memory_order_relaxed); }
static const char* mode_name(core::Mode mode) {
    switch (mode) {
        case core::Mode::Observe: return "Observe";
        case core::Mode::Analyze: return "Analyze";
        case core::Mode::Profile: return "Profile";
    }
    return "Unknown";
}

int main(int argc, char** argv) {
    bool check_config = false;
    std::string config_path = "config.yaml";
    bool have_path = false;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--help" || arg == "-h") {
            std::cout << "Usage: " << argv[0] << " [--check-config] [config.yaml]\n";
            return 0;
        }
        if (arg == "--check-config") check_config = true;
        else if (!have_path && !arg.empty() && arg.front() != '-') { config_path = arg; have_path = true; }
        else { std::cerr << "Unknown argument: " << arg << "\n"; return 1; }
    }
    core::AgentConfig cfg;
    std::string error;
    if (!core::ReadConfig(config_path, cfg, error)) { std::cerr << error << "\n"; return 1; }
    if (check_config) { std::cout << "Configuration valid: " << config_path << "\n"; return 0; }
    if (::geteuid() != 0) { std::cerr << "Run the agent as root (Docker, netns, perf and kernel controls).\n"; return 1; }
    core::KernelAbi abi;
    if (!core::ReadKernelAbi(cfg.p2_proc_hist_path, abi, error)) { std::cerr << error << "\n"; return 1; }
    if (static_cast<std::size_t>(cfg.p3_pfn_hist_max) >= abi.capacity) {
        std::cerr << "p3_pfn_hist_max must be smaller than the kernel buffer capacity\n";
        return 1;
    }
    const int lock_fd = ::open("/run/Koseishugi-agent.lock", O_CREAT | O_RDWR | O_CLOEXEC, 0600);
    if (lock_fd < 0 || ::flock(lock_fd, LOCK_EX | LOCK_NB) < 0) {
        std::cerr << "Cannot acquire the agent lock; another agent may be running.\n";
        if (lock_fd >= 0) ::close(lock_fd);
        return 1;
    }
    std::signal(SIGINT, handle_signal);
    std::signal(SIGTERM, handle_signal);
    ui::TuiLogger log(".", cfg.title);
    core::Monitor monitor(cfg.netdev_iface, cfg.p0_burst_threshold_kib);
    core::Pressure detector;
    detector.SetServiceBlacklist(cfg.p1_blacklist);
    core::ProfilerConfig sampling;
    sampling.perf_event_config = cfg.p2_perf_event_config;
    sampling.sampling_interval = cfg.p2_sampling_interval;
    sampling.duration_ms = cfg.p2_duration_ms;
    sampling.ring_pages = cfg.p2_ring_pages;
    sampling.proc_hist_path = cfg.p2_proc_hist_path;
    sampling.output_dir = cfg.p2_output_dir;
    sampling.cgroup_resolve = cfg.p2_cgroup_resolve;
    sampling.histogram_logging = cfg.histogram_logging;
    core::Profiler profiler(sampling);
    core::PolicyConfig placement;
    placement.pfn_percentile = cfg.p3_pfn_percentile;
    placement.pfn_hist_max = cfg.p3_pfn_hist_max;
    placement.proc_hist_path = cfg.p2_proc_hist_path;
    placement.histogram_logging = cfg.histogram_logging;
    core::Policy policy(placement);
    const auto initial = policy.Clear();
    if (!initial.ok) { std::cerr << initial.note << "\n"; ::close(lock_fd); return 1; }
    log.log_info("event=AGENT_START config=" + config_path + " iface=" + cfg.netdev_iface +
                 " tick_ms=" + std::to_string(cfg.tick_ms) + " gate=inactive");
    core::ControlLoop control(cfg.p0_idle_threshold_ticks);
    ui::TuiModel::Snapshot snapshot;
    std::thread worker;
    struct JoinWorker {
        std::thread& worker;
        ~JoinWorker() { stop_requested.store(true); if (worker.joinable()) worker.join(); }
    };
    std::atomic<bool> sampling_done{false};
    core::ProfilerResult sample;
    JoinWorker join_worker{worker};
    using Clock = std::chrono::steady_clock;
    const auto start = Clock::now();
    auto next = start;
    auto cooldown_until = start;
    while (!stop_requested.load(std::memory_order_relaxed)) {
        const auto now = Clock::now();
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - start).count();
        const auto traffic = monitor.Tick();
        const bool was_profiling = control.mode() == core::Mode::Profile;
        if (was_profiling && sampling_done.load(std::memory_order_acquire)) {
            worker.join();
            if (sample.ok && !sample.hist.empty()) {
                const auto update = policy.Process(sample.hist, sample.log_path);
                if (update.ok) log.log_info("event=WORKING_SET_UPDATE service=" + sample.target.service +
                    " pages=" + std::to_string(update.pages_submitted) + " note=" + update.note);
                else log.log_warn("event=WORKING_SET_UPDATE_FAILED note=" + update.note);
            } else log.log_warn("event=PROFILE_NO_UPDATE note=" + sample.note);
            log.log_info("event=PROFILE_DONE records=" + std::to_string(sample.records) +
                         " lost_samples=" + std::to_string(sample.lost_events));
            control.ProfileFinished();
            cooldown_until = Clock::now() + std::chrono::milliseconds(cfg.p2_cooldown_ms);
            snapshot.is_current = false;
        }
        if (!was_profiling && control.mode() == core::Mode::Observe && now >= cooldown_until &&
            traffic.ready && traffic.read_ok) {
            control.Observe(traffic.pressure_on);
            if (control.mode() == core::Mode::Analyze) {
                detector.Start();
                const auto report = detector.Tick(elapsed, cfg.netdev_iface, &stop_requested);
                detector.Stop();
                snapshot = {};
                snapshot.valid = true;
                snapshot.header = "t_ms=" + std::to_string(elapsed) + " rx_delta_kib=" + std::to_string(traffic.delta_kib);
                for (const auto& service : report.topk) {
                    snapshot.lines.push_back(service.service + " recv_kib=" + std::to_string(service.recv_sum_kib) +
                        " fan_out=" + std::to_string(service.out_conn) + " fan_in=" + std::to_string(service.in_conn));
                }
                if (!report.note.empty()) log.log_info("event=QUEUE_ANALYSIS note=" + report.note);
                if (!report.ok) {
                    control.AnalysisFailed();
                    log.log_warn("event=QUEUE_ANALYSIS_FAILED");
                } else {
                    const bool eligible = !report.topk.empty() &&
                        report.topk.front().recv_sum_kib >= cfg.pressure_threshold_kib;
                    control.Analyze(eligible);
                    if (eligible) {
                        const auto service = report.topk.front().service;
                        sampling_done.store(false, std::memory_order_relaxed);
                        snapshot.is_current = true;
                        log.log_info("event=PROFILE_START service=" + service +
                                     " period=" + std::to_string(cfg.p2_sampling_interval));
                        try {
                            worker = std::thread([&, service] {
                                try { sample = profiler.RunOnceForService(service, "", &stop_requested); }
                                catch (const std::exception& e) { sample = {}; sample.note = e.what(); }
                                sampling_done.store(true, std::memory_order_release);
                            });
                        } catch (const std::exception& e) {
                            control.ProfileFinished();
                            snapshot.is_current = false;
                            log.log_warn(std::string("event=PROFILE_START_FAILED note=") + e.what());
                        }
                    }
                }
            }
        }
        if (control.AgingDue()) {
            const auto aged = policy.TrimCold(cfg.p0_idle_trim_pct);
            if (aged.ok) {
                control.AgingCompleted();
                log.log_info("event=AGE_COLD gate=inactive pct=" + std::to_string(cfg.p0_idle_trim_pct));
            } else log.log_warn("event=AGE_COLD_FAILED note=" + aged.note);
        }
        if (!traffic.read_ok && !traffic.warmup)
            log.log_warn(traffic.counter_reset ? "event=RX_COUNTER_RESET" : "event=RX_READ_FAILED");
        ui::TuiModel view;
        view.title = cfg.title;
        view.pid = ::getpid();
        view.t_ms = elapsed;
        view.processor = mode_name(control.mode());
        view.iface = cfg.netdev_iface;
        view.tick_ms = cfg.tick_ms;
        view.threshold_kib = cfg.p0_burst_threshold_kib;
        view.pressure_threshold_kib = cfg.pressure_threshold_kib;
        view.p0_ready = traffic.ready;
        view.read_ok = traffic.read_ok;
        view.rx_delta_kib = traffic.delta_kib;
        view.pressure_on = traffic.pressure_on;
        view.pebs_kernel_ok = true; // ABI verified before starting; each mutation checks again.
        view.snapshot = snapshot;
        view.log_path = log.log_path();
        log.render(view);
        next += std::chrono::milliseconds(cfg.tick_ms);
        if (next < Clock::now()) next = Clock::now() + std::chrono::milliseconds(cfg.tick_ms);
        while (!stop_requested.load(std::memory_order_relaxed) && Clock::now() < next)
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    if (worker.joinable()) worker.join();
    const auto cleared = policy.Clear();
    if (cleared.ok) log.log_info("event=SHUTDOWN gate=inactive");
    else log.log_warn("event=SHUTDOWN_CLEAR_FAILED note=" + cleared.note);
    log.clear();
    ::close(lock_fd);
    return cleared.ok ? 0 : 1;
}
