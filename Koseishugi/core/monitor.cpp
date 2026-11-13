#include "core/monitor.h"

#include "pkg/traffic.h"

namespace core {

Monitor::Monitor(std::string iface, double threshold_kib)
    : iface_(std::move(iface)), threshold_kib_(threshold_kib) {}

MonitorTick Monitor::Tick() {
    MonitorTick t;
    t.iface = iface_;

    std::uint64_t rx_bytes = 0;
    if (!traffic::read_rx_bytes(iface_, rx_bytes)) {
        t.read_ok = false;
        return t;
    }
    t.rx_bytes = rx_bytes;

    if (!have_prev_) {
        have_prev_ = true;
        prev_rx_bytes_ = rx_bytes;

        t.warmup = true;
        t.read_ok = false;
        t.ready = false;
        return t;
    }

    if (rx_bytes < prev_rx_bytes_) {
        prev_rx_bytes_ = rx_bytes;

        t.counter_reset = true;
        t.read_ok = false;
        t.ready = false;
        return t;
    }

    const std::uint64_t delta_bytes = rx_bytes - prev_rx_bytes_;
    prev_rx_bytes_ = rx_bytes;

    t.delta_kib = static_cast<double>(delta_bytes) / 1024.0;
    t.pressure_on = (t.delta_kib >= threshold_kib_);
    t.read_ok = true;
    t.ready = true;
    return t;
}

} // namespace core
