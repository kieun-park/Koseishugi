#include "tui.h"
#include <chrono>
#include <cctype>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <ctime>
#include <cstdio>
#include <sys/ioctl.h>
#include <unistd.h>

namespace ui {

static int get_terminal_width() {
    struct winsize ws;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col >= 40)
        return (int)ws.ws_col;
    return 118;  // fallback for non-TTY or very narrow terminals
}

static void tui_enter_alt_screen() {
    std::cout << "\033[?1049h"; // enter alt screen
    std::cout << "\033[?25l";   // hide cursor
}

static void tui_leave_alt_screen() {
    std::cout << "\033[?25h";   // show cursor
    std::cout << "\033[?1049l"; // leave alt screen
}

static void move_home() {
    std::cout << "\033[H";
}

static void clear_to_end() {
    std::cout << "\033[J";
}

static constexpr const char* ANSI_RESET = "\033[0m";
static constexpr const char* ANSI_GREEN = "\033[32m";
static constexpr const char* ANSI_DIM = "\033[2m";

static bool is_ansi_escape_start(const std::string& s, size_t i) {
    return i + 1 < s.size() && s[i] == '\033' && s[i + 1] == '[';
}

static size_t skip_ansi_escape(const std::string& s, size_t i) {
    size_t j = i;
    if (j < s.size() && s[j] == '\033') j++;
    if (j < s.size() && s[j] == '[') j++;
    while (j < s.size()) {
        unsigned char c = (unsigned char)s[j++];
        if (c >= 0x40 && c <= 0x7E) break; // final byte
    }
    return j;
}

static size_t utf8_next(const std::string& s, size_t i) {
    if (i >= s.size()) return i;
    unsigned char c = (unsigned char)s[i];
    if ((c & 0x80) == 0x00) return i + 1;
    if ((c & 0xE0) == 0xC0) return std::min(i + 2, s.size());
    if ((c & 0xF0) == 0xE0) return std::min(i + 3, s.size());
    if ((c & 0xF8) == 0xF0) return std::min(i + 4, s.size());
    return i + 1;
}

static int visible_width(const std::string& s) {
    int w = 0;
    for (size_t i = 0; i < s.size();) {
        if (is_ansi_escape_start(s, i)) {
            i = skip_ansi_escape(s, i);
            continue;
        }
        i = utf8_next(s, i);
        w++;
    }
    return w;
}

static std::string trunc_pad_visible(const std::string& s, int width) {
    if (width <= 0) return std::string();

    const int ell = 3;
    const bool need_ell = visible_width(s) > width;
    const int target = need_ell ? std::max(0, width - ell) : width;

    std::string out;
    out.reserve(s.size() + 16);

    int w = 0;
    for (size_t i = 0; i < s.size() && w < target;) {
        if (is_ansi_escape_start(s, i)) {
            size_t j = skip_ansi_escape(s, i);
            out.append(s, i, j - i);
            i = j;
            continue;
        }
        size_t j = utf8_next(s, i);
        out.append(s, i, j - i);
        i = j;
        w++;
    }

    if (need_ell) out += "...";
    out += ANSI_RESET;

    int pad = width - visible_width(out);
    if (pad > 0) out.append((size_t)pad, ' ');
    return out;
}

static void print_border_top(int inner_w) {
    std::cout << "┌" << std::string(inner_w, '-') << "┐\n";
}

static void print_border_mid(int inner_w) {
    std::cout << "├" << std::string(inner_w, '-') << "┤\n";
}

static void print_border_bottom(int inner_w) {
    std::cout << "└" << std::string(inner_w, '-') << "┘\n";
}

static void print_line(const std::string& content, int inner_w) {
    std::cout << "│" << trunc_pad_visible(content, inner_w) << "│\n";
}


static std::string mode_boxes(const std::string& mode) {
    const char* modes[] = {"P0", "P1", "P2", "P3"};
    std::ostringstream oss;
    oss << "mode=";
    for (const char* m : modes) {
        const bool cur = (mode == m);
        oss << " [";
        if (cur) oss << ANSI_GREEN;
        oss << (cur ? "■" : "□") << m;
        if (cur) oss << ANSI_RESET;
        oss << "]";
    }
    return oss.str();
}

std::string TuiLogger::sanitize_filename(const std::string& s) {
    std::string out;
    out.reserve(s.size());
    for (unsigned char c : s) {
        if (std::isalnum(c) || c == '.' || c == '_' || c == '-') out.push_back((char)c);
        else if (std::isspace(c)) out.push_back('_');
        else out.push_back('_');
    }
    if (out.empty()) out = "Untitled";
    return out;
}

static std::string wall_time_string() {
    using namespace std::chrono;

    auto now = system_clock::now();
    auto sec = time_point_cast<std::chrono::seconds>(now);
    auto ms = duration_cast<milliseconds>(now - sec).count();

    std::time_t tt = system_clock::to_time_t(sec);
    std::tm tm{};
    localtime_r(&tt, &tm);  // thread-safe

    char buf[64];
    std::snprintf(buf, sizeof(buf),
                  "%04d-%02d-%02d %02d:%02d:%02d.%03lld",
                  tm.tm_year + 1900,
                  tm.tm_mon + 1,
                  tm.tm_mday,
                  tm.tm_hour,
                  tm.tm_min,
                  tm.tm_sec,
                  (long long)ms);
    return std::string(buf);
}

TuiLogger::TuiLogger(std::string project_root, std::string title)
    : project_root_(std::move(project_root)), title_(std::move(title)) {
    std::string fname = sanitize_filename(title_);
    log_path_ = project_root_ + "/" + fname + ".log";
    log_.open(log_path_, std::ios::out | std::ios::app); // append
}

TuiLogger::~TuiLogger() {
    if (tui_inited_) {
        tui_leave_alt_screen();
        std::cout.flush();
    }
}

bool TuiLogger::log_ok() const {
    return log_.is_open();
}

const std::string& TuiLogger::log_path() const {
    return log_path_;
}

void TuiLogger::log_line(const std::string& level, const std::string& msg) {
    if (!log_.is_open()) return;
    log_ << wall_time_string() << " " << level << " " << msg << "\n";
    log_.flush(); // ok for now; can batch later
}

void TuiLogger::log_info(const std::string& msg) { log_line("INFO", msg); }
void TuiLogger::log_warn(const std::string& msg) { log_line("WARN", msg); }

void TuiLogger::clear() {
    if (!tui_inited_) {
        tui_enter_alt_screen();
        tui_inited_ = true;
    }
    move_home();
    clear_to_end();
    std::cout.flush();
}

void TuiLogger::render(const TuiModel& m) {
    if (!tui_inited_) {
        tui_enter_alt_screen();
        tui_inited_ = true;
    }
    move_home();

    const int frame_w = get_terminal_width();
    const int inner_w = frame_w - 2;
    print_border_top(inner_w);
    {
        static const char* const GLYPH[3] = {
            "╔══ ╔═╗ ╔╗╔ ╔══ ═╦═ ╔═╗ ╦ ╦ ╔══ ═╦═ ═╪═ ╦ ╦ ═╪═ ╔══ ╔╦╗",
            "║   ║ ║ ║╚╗ ╚═╗  ║  ╠╦╝ ║ ║ ║    ║   ║  ╚╦╝  ║  ╚═╗ ║║║",
            "╚══ ╚═╝ ╚ ╚ ══╝  ╩  ╩╚╗ ╚═╝ ╚══  ╩  ═╧═  ╩  ═╧═ ══╝ ╩ ╩",
        };
        const int art_w = 55;
        const int pad = std::max(0, (inner_w - art_w) / 2);
        const std::string indent(pad, ' ');
        for (const char* g : GLYPH) {
            std::ostringstream row;
            row << indent << "\033[1;38;5;124m" << g << "\033[0m";
            print_line(row.str(), inner_w);
        }
    }
    print_line(" ", inner_w);
    {
        const int tag_w = visible_width(m.title);
        const int pad = std::max(0, (inner_w - tag_w) / 2);
        std::ostringstream tb;
        tb << std::string(pad, ' ') << "\033[2m" << m.title << "\033[0m";
        print_line(tb.str(), inner_w);
    }
    print_line(" ", inner_w);
    std::ostringstream meta;
    meta << "  " << m.title << " | Runtime Agent | pid=" << m.pid << " | " << mode_boxes(m.processor);
    print_line(meta.str(), inner_w);
    print_border_mid(inner_w);
    print_line("  CONFIGURATION", inner_w);
    {
        std::ostringstream c1;
        c1 << "  net=" << m.iface
           << " | tick=" << m.tick_ms << "ms"
           << " | RX threshold=" << std::fixed << std::setprecision(1) << m.threshold_kib << " KiB/tick"
           << " | service threshold=" << std::fixed << std::setprecision(3) << m.pressure_threshold_kib << " KiB"
           << " | kernel patch=" << (m.pebs_kernel_ok ? "OK" : "MISSING");
        print_line(c1.str(), inner_w);
    }
    {
        std::ostringstream c2;
        c2 << "  log_file=" << m.log_path;
        if (!m.log_path.empty() && !log_ok()) c2 << " (open failed)";
        print_line(c2.str(), inner_w);
    }
    print_border_mid(inner_w);
    print_line("  RUNTIME STATUS", inner_w);
    {
        std::ostringstream st;
        st << "  network RX=";
        if (!m.p0_ready) st << "N/A (warmup)";
        else if (!m.read_ok) st << "N/A (read failed)";
        else st << std::fixed << std::setprecision(3) << m.rx_delta_kib << " KiB";
        st << " | pressure=";
        if (m.pressure_on) st << ANSI_GREEN << "ON" << ANSI_RESET;
        else st << "OFF";
        print_line(st.str(), inner_w);
    }
    if (!m.snapshot.valid) {
        print_line(std::string("  ") + ANSI_DIM + "Pressured Services: (none)" + ANSI_RESET, inner_w);
    } else {
        std::ostringstream hdr;
        hdr << "  Pressured Services: "
            << (m.snapshot.is_current ? (std::string(ANSI_GREEN) + m.snapshot.header + ANSI_RESET) : m.snapshot.header);
        print_line(hdr.str(), inner_w);

        if (m.snapshot.lines.empty()) {
            print_line(std::string("  ") + ANSI_DIM + "(no services >= threshold)" + ANSI_RESET, inner_w);
        } else {
            for (const auto& line : m.snapshot.lines) {
                if (m.snapshot.is_current) {
                    print_line(std::string("  ") + ANSI_GREEN + line + ANSI_RESET, inner_w);
                } else {
                    print_line(std::string("  ") + line, inner_w);
                }
            }
        }
    }

    print_border_bottom(inner_w);

    clear_to_end();
    std::cout.flush();
}

} // namespace ui