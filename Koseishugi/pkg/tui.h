#pragma once
#include <cstdint>
#include <fstream>
#include <vector>
#include <string>

namespace ui {
struct TuiModel {
    std::string title;        // display title
    int pid = 0;
    std::int64_t t_ms = 0;

    std::string processor;    // "P0"
    std::string iface;        // "lo"
    int tick_ms = 1000;

    double threshold_kib = 0.0;
    double pressure_threshold_kib = 1.0;

    bool p0_ready = false;
    bool read_ok = false;
    double rx_delta_kib = 0.0;
    bool pressure_on = false;
    bool pebs_kernel_ok = false;
    struct Snapshot {
        bool valid = false;
        bool is_current = false;
        std::string header;               // e.g., "[18:13:36.610] t_ms=82000 ..."
        std::vector<std::string> lines;   // already formatted text lines
    } snapshot;

    std::string log_path;     // for display only
};

class TuiLogger {
public:
    TuiLogger(std::string project_root, std::string title);
    ~TuiLogger();

    bool log_ok() const;
    const std::string& log_path() const;
    void render(const TuiModel& m);
    void clear();
    void log_info(const std::string& msg);
    void log_warn(const std::string& msg);

private:
    std::string project_root_;
    std::string title_;
    std::string log_path_;
    std::ofstream log_;

    bool tui_inited_ = false;

    static std::string sanitize_filename(const std::string& s);
    void log_line(const std::string& level, const std::string& msg);
};

} // namespace ui