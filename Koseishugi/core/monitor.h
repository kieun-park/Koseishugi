#pragma once

#include <cstdint>
#include <string>

namespace core {
struct MonitorTick {
    bool read_ok = false;     // True if /proc/net/dev read succeeded and produced a delta.
    bool warmup = false;      // True for the first successful read (no delta yet).
    bool counter_reset = false; // True if counter went backwards.
    bool ready = false;       // True when delta_kib is valid.
    std::string iface;
    std::uint64_t rx_bytes = 0;
    double delta_kib = 0.0;
    bool pressure_on = false; // delta_kib >= threshold_kib
};

class Monitor {
public:
    Monitor(std::string iface, double threshold_kib);

    const std::string& iface() const { return iface_; }
    double threshold_kib() const { return threshold_kib_; }
    MonitorTick Tick();

private:
    std::string iface_;
    double threshold_kib_ = 0.0;

    bool have_prev_ = false;
    std::uint64_t prev_rx_bytes_ = 0;
};

} // namespace core


#include <limits>

namespace core {
enum class Mode { Observe, Analyze, Profile };
class ControlLoop {
public:
    explicit ControlLoop(int aging_ticks) : aging_ticks_(aging_ticks) {}
    Mode mode() const { return mode_; }
    int idle_ticks() const { return idle_ticks_; }
    void Observe(bool traffic) {
        if (mode_ != Mode::Observe) return;
        if (traffic) mode_ = Mode::Analyze;
        else RecordIdle();
    }
    void Analyze(bool pressure) {
        if (mode_ != Mode::Analyze) return;
        if (pressure) { idle_ticks_ = 0; mode_ = Mode::Profile; }
        else { RecordIdle(); mode_ = Mode::Observe; }
    }
    void AnalysisFailed() { mode_ = Mode::Observe; }
    void ProfileFinished() { mode_ = Mode::Observe; }
    bool AgingDue() const { return mode_ == Mode::Observe && idle_ticks_ >= aging_ticks_; }
    void AgingCompleted() { idle_ticks_ = 0; }
private:
    void RecordIdle() { if (idle_ticks_ < std::numeric_limits<int>::max()) ++idle_ticks_; }
    Mode mode_ = Mode::Observe;
    int idle_ticks_ = 0;
    int aging_ticks_;
};
} // namespace core


#include <cstdint>
#include <string>
#include <vector>
namespace core {
struct AgentConfig {
    int tick_ms = 2000;
    std::string netdev_iface = "lo";
    double p0_burst_threshold_kib = 10000.0;
    double pressure_threshold_kib = 1.0;
    std::string title = "Koseishugi";
    uint64_t p2_perf_event_config = 0x20d1;
    int p2_sampling_interval = 1000;
    int p2_duration_ms = 30000;
    std::string p2_proc_hist_path = "/proc/pebs_page_hist";
    std::string p2_output_dir = "logs";
    std::string p2_cgroup_resolve = "auto";
    int p2_cooldown_ms = 0;
    int p2_ring_pages = 256;
    int p3_pfn_percentile = 80;
    int p3_pfn_hist_max = 65536;
    bool histogram_logging = false;
    std::vector<std::string> p1_blacklist;
    int p0_idle_threshold_ticks = 9;
    int p0_idle_trim_pct = 20;
};
bool ReadConfig(const std::string& path, AgentConfig& cfg, std::string& error);
} // namespace core
