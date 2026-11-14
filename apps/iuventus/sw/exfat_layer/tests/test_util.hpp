// test_util.hpp: shared helpers of the exFAT layer tests (seeds, images, external referees)
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <cstdint>
#include <functional>
#include <map>
#include <optional>
#include <random>
#include <set>
#include <stdexcept>
#include <string>
#include <system_error>
#include <vector>

#include "iuv_exfat/volume.hpp"

namespace iuv_test {

constexpr int SKIP = 77;
constexpr uint64_t MIB = 1ull << 20;
constexpr uint64_t CLUSTER = 512 * 1024;

using Files = std::map<std::string, std::vector<uint8_t>>;

struct TestFailure : std::runtime_error {
    using std::runtime_error::runtime_error;
};

#define CHECK(cond)                                                                                                     \
    do {                                                                                                                \
        if (!(cond))                                                                                                    \
            throw ::iuv_test::TestFailure(std::string(__FILE__) + ":" + std::to_string(__LINE__) + ": CHECK(" #cond ")"); \
    } while (0)

#define CHECK_EQ(a, b)                                                                                                 \
    do {                                                                                                                \
        const auto va_ = (a);                                                                                           \
        const auto vb_ = (b);                                                                                           \
        if (!(va_ == vb_))                                                                                              \
            throw ::iuv_test::TestFailure(std::string(__FILE__) + ":" + std::to_string(__LINE__) + ": " #a " == " #b \
                                          " (" + std::to_string(va_) + " vs " + std::to_string(vb_) + ")");        \
    } while (0)

class TempDir {
public:
    explicit TempDir(const std::string& name);
    ~TempDir();
    const std::string& path() const { return path_; }
    std::string file(const std::string& name) const { return path_ + "/" + name; }

private:
    std::string path_;
};

// Value of a numeric environment variable, empty when it is unset or empty.
std::optional<uint64_t> env_u64(const char* name);
// True when fn throws a system_error with the given code; any other error propagates.
bool throws_errc(std::errc code, const std::function<void()>& fn);
// Names directly below dir (root is "") among the file paths and the directories, all with a leading '/'.
template <class FileMap>
std::set<std::string> children_of(const std::string& dir, const FileMap& files, const std::set<std::string>& dirs)
{
    std::set<std::string> names;
    auto add = [&](const std::string& path) {
        if (path.rfind(dir + "/", 0) == 0 && path.find('/', dir.size() + 1) == std::string::npos)
            names.insert(path.substr(dir.size() + 1));
    };
    for (const auto& [path, content] : files)
        add(path);
    for (const auto& sub : dirs)
        add(sub);
    return names;
}

// Seed from IUV_SEED or random; printed so a failure can be replayed.
uint64_t test_seed(const std::string& test_name);
// Runs body; returns 0, 1 on failure (with the replay hint) or SKIP when the tools are missing.
int run_test(const std::string& name, const std::function<void(uint64_t seed, TempDir& tmp)>& body);

int run_cmd(const std::string& cmd, std::string* output = nullptr);
void make_image(const std::string& path, uint64_t bytes);
// No partition table: LBA 0 is the exFAT boot sector.
void make_bare_image(const std::string& path, uint64_t bytes, const std::string& boundary);
// Sparse copy of the exFAT partition of an mkfs -P gpt image (or of a bare image).
void extract_partition(const std::string& image, const std::string& out);
// fsck.exfat -n plus the independent bitmap/owner walk on a partition copy; prints both outputs on failure.
// mid_session accepts VolumeDirty and unfinished outputs, the state while reservations are open.
void check_volume(const std::string& image, TempDir& tmp, const std::string& phase, bool mid_session = false);

std::vector<uint8_t> random_bytes(std::mt19937_64& rng, uint64_t n);
std::string random_name(std::mt19937_64& rng, size_t max_len = 24);
std::unique_ptr<iuv_exfat::Volume> open_volume(const std::string& image, bool read_only = false);

// Independent DIGEST_FILL output: FILL_BYTES of pattern then the record.
std::vector<uint8_t> digest_fill_expected(const std::vector<std::vector<uint8_t>>& inputs, uint64_t fill, uint32_t seed);

// Every file finished, of its size and with its content.
void verify_files(iuv_exfat::Volume& vol, const Files& files);
// Entry names directly in dir (root is "").
std::set<std::string> listed_names(iuv_exfat::Volume& vol, const std::string& dir);

} // namespace iuv_test
