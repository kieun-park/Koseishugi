#include "pkg/util.h"

#include <cctype>
#include <fstream>
#include <memory>
#include <sstream>
#include <cstdio>

namespace util {

std::string trim(const std::string& s) {
    size_t b = 0;
    while (b < s.size() && std::isspace(static_cast<unsigned char>(s[b]))) b++;
    size_t e = s.size();
    while (e > b && std::isspace(static_cast<unsigned char>(s[e - 1]))) e--;
    return s.substr(b, e - b);
}

bool read_file(const std::string& path, std::string& out) {
    std::ifstream in(path);
    if (!in.is_open()) return false;
    std::ostringstream ss;
    ss << in.rdbuf();
    out = ss.str();
    return true;
}

std::string run_cmd(const std::string& cmd) {
    std::string out;
    const std::string bounded = "timeout --signal=TERM --kill-after=1s 5s " + cmd;
    std::unique_ptr<FILE, decltype(&pclose)> pipe(popen(bounded.c_str(), "r"), pclose);
    if (!pipe) return out;
    char buf[4096];
    while (fgets(buf, sizeof(buf), pipe.get())) out += buf;
    return out;
}

} // namespace util
