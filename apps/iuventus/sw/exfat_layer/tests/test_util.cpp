// test_util.cpp: shared helpers of the exFAT layer tests (seeds, images, external referees)
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#include "test_util.hpp"

#include <array>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>

#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>

#include "iuv_exfat/util.hpp"

namespace iuv_test {

namespace fs = std::filesystem;

TempDir::TempDir(const std::string& name)
{
    path_ = std::string(IUV_TEST_TMP) + "/" + name + "." + std::to_string(::getpid());
    fs::remove_all(path_);
    fs::create_directories(path_);
}

TempDir::~TempDir()
{
    if (!std::getenv("IUV_KEEP_TMP")) {
        std::error_code ec;
        fs::remove_all(path_, ec);
    }
}

std::optional<uint64_t> env_u64(const char* name)
{
    const char* env = std::getenv(name);
    if (!env || !*env)
        return std::nullopt;
    return iuv_exfat::parse_u64(env);
}

bool throws_errc(std::errc code, const std::function<void()>& fn)
{
    try {
        fn();
    } catch (const std::system_error& e) {
        if (e.code() == code)
            return true;
        throw;
    }
    return false;
}

uint64_t test_seed(const std::string& test_name)
{
    const uint64_t seed =
        env_u64("IUV_SEED").value_or((static_cast<uint64_t>(std::random_device {}()) << 32) ^ std::random_device {}());
    std::printf("[%s] seed=%llu (replay: IUV_SEED=%llu)\n", test_name.c_str(), static_cast<unsigned long long>(seed),
                static_cast<unsigned long long>(seed));
    std::fflush(stdout);
    return seed;
}

int run_test(const std::string& name, const std::function<void(uint64_t seed, TempDir& tmp)>& body)
{
    if (std::string(IUV_MKFS).empty() || std::string(IUV_FSCK).empty() || std::string(IUV_PYTHON).empty()) {
        std::printf("[%s] SKIP: mkfs.exfat, fsck.exfat or python3 not found\n", name.c_str());
        return SKIP;
    }
    const uint64_t seed = test_seed(name);
    try {
        TempDir tmp(name);
        body(seed, tmp);
    } catch (const std::exception& e) {
        std::printf("[%s] FAIL: %s\n[%s] replay with IUV_SEED=%llu\n", name.c_str(), e.what(), name.c_str(),
                    static_cast<unsigned long long>(seed));
        return 1;
    }
    std::printf("[%s] PASS\n", name.c_str());
    return 0;
}

int run_cmd(const std::string& cmd, std::string* output)
{
    FILE* p = ::popen((cmd + " 2>&1").c_str(), "r");
    if (!p)
        throw std::runtime_error("popen failed: " + cmd);
    std::array<char, 4096> buf {};
    std::string out;
    size_t n = 0;
    while ((n = std::fread(buf.data(), 1, buf.size(), p)) > 0)
        out.append(buf.data(), n);
    const int st = ::pclose(p);
    if (output)
        *output = out;
    return WIFEXITED(st) ? WEXITSTATUS(st) : 128;
}

namespace {

void mkfs_image(const std::string& path, uint64_t bytes, const std::string& layout, const std::string& boundary)
{
    fs::remove(path);
    std::ofstream {path};
    fs::resize_file(path, bytes);
    std::string out;
    if (run_cmd(std::string(IUV_MKFS) + " -q " + layout + "-c 512K -b " + boundary + " '" + path + "'", &out) != 0)
        throw std::runtime_error("mkfs.exfat failed: " + out);
}

} // namespace

void make_image(const std::string& path, uint64_t bytes) { mkfs_image(path, bytes, "-P gpt ", "1M"); }

void make_bare_image(const std::string& path, uint64_t bytes, const std::string& boundary)
{
    mkfs_image(path, bytes, "", boundary);
}

void extract_partition(const std::string& image, const std::string& out)
{
    const int in = ::open(image.c_str(), O_RDONLY);
    if (in < 0)
        throw std::runtime_error("open " + image);
    std::array<uint8_t, iuv_exfat::LBA_BYTES> sec {};
    uint64_t first = 0;
    uint64_t len = static_cast<uint64_t>(::lseek(in, 0, SEEK_END));
    if (::pread(in, sec.data(), sec.size(), 0) != static_cast<ssize_t>(sec.size())) {
        ::close(in);
        throw std::runtime_error("short image " + image);
    }
    if (std::memcmp(&sec[3], "EXFAT   ", 8) != 0) {
        std::array<uint8_t, iuv_exfat::LBA_BYTES> hdr {};
        std::array<uint8_t, 128> ent {};
        if (::pread(in, hdr.data(), hdr.size(), iuv_exfat::LBA_BYTES) != static_cast<ssize_t>(hdr.size()) ||
            std::memcmp(hdr.data(), "EFI PART", 8) != 0) {
            ::close(in);
            throw std::runtime_error("no GPT in " + image);
        }
        uint64_t ent_lba = 0;
        std::memcpy(&ent_lba, &hdr[72], 8);
        if (::pread(in, ent.data(), 128, static_cast<off_t>(ent_lba * iuv_exfat::LBA_BYTES)) != 128) {
            ::close(in);
            throw std::runtime_error("short GPT in " + image);
        }
        uint64_t last = 0;
        std::memcpy(&first, &ent[32], 8);
        std::memcpy(&last, &ent[40], 8);
        len = (last - first + 1) * iuv_exfat::LBA_BYTES;
        first *= iuv_exfat::LBA_BYTES;
    }
    const int o = ::open(out.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (o < 0 || ::ftruncate(o, static_cast<off_t>(len)) != 0) {
        ::close(in);
        throw std::runtime_error("create " + out);
    }
    std::vector<uint8_t> buf(4 * MIB);
    off_t pos = static_cast<off_t>(first);
    const off_t end = static_cast<off_t>(first + len);
    while (pos < end) {
        const off_t data = ::lseek(in, pos, SEEK_DATA);
        if (data < 0 || data >= end)
            break;
        off_t hole = ::lseek(in, data, SEEK_HOLE);
        if (hole < 0 || hole > end)
            hole = end;
        for (off_t p = data; p < hole;) {
            const size_t n = static_cast<size_t>(std::min<off_t>(static_cast<off_t>(buf.size()), hole - p));
            if (::pread(in, buf.data(), n, p) != static_cast<ssize_t>(n) ||
                ::pwrite(o, buf.data(), n, p - static_cast<off_t>(first)) != static_cast<ssize_t>(n)) {
                ::close(in);
                ::close(o);
                throw std::runtime_error("copy failed for " + image);
            }
            p += static_cast<off_t>(n);
        }
        pos = hole;
    }
    ::close(in);
    ::close(o);
}

void check_volume(const std::string& image, TempDir& tmp, const std::string& phase, bool mid_session)
{
    const std::string part = tmp.file("referee_partition.img");
    extract_partition(image, part);
    std::string fsck_out;
    const int fsck_rc = run_cmd(std::string(IUV_FSCK) + " -n '" + part + "'", &fsck_out);
    std::string walk_out;
    const int walk_rc = run_cmd(std::string(IUV_PYTHON) + " -I " + IUV_BITMAP_CHECK + (mid_session ? " --allow-unfinished --allow-dirty" : "") +
                                    " '" + part + "'",
                                &walk_out);
    fs::remove(part);
    if (fsck_rc != 0 || walk_rc != 0) {
        std::cout << "---- fsck.exfat -n (" << phase << ") rc=" << fsck_rc << "\n" << fsck_out << "---- owner walk rc=" << walk_rc
                  << "\n" << walk_out;
        throw TestFailure("volume not clean after phase: " + phase);
    }
}

std::vector<uint8_t> random_bytes(std::mt19937_64& rng, uint64_t n)
{
    std::vector<uint8_t> v(n);
    size_t i = 0;
    for (; i + 8 <= n; i += 8) {
        const uint64_t r = rng();
        std::memcpy(&v[i], &r, 8);
    }
    for (; i < n; ++i)
        v[i] = static_cast<uint8_t>(rng());
    return v;
}

std::string random_name(std::mt19937_64& rng, size_t max_len)
{
    static const char* const PIECES[] = {"a", "B", "c", "D", "e", "x", "Y", "z", "0", "7", "_", "-", " ", ".",
                                         "\xC3\xA9", "\xC3\x9F", "\xD0\x96", "\xE4\xB8\xAD", "\xF0\x9F\x98\x80"};
    const size_t len = 1 + rng() % max_len;
    std::string s;
    for (size_t i = 0; i < len; ++i)
        s += PIECES[rng() % std::size(PIECES)];
    while (!s.empty() && (s.back() == ' ' || s.back() == '.'))
        s.pop_back();
    while (!s.empty() && s.front() == ' ')
        s.erase(s.begin());
    return s.empty() ? "n" + std::to_string(rng() % 1000) : s;
}

std::unique_ptr<iuv_exfat::Volume> open_volume(const std::string& image, bool read_only)
{
    iuv_exfat::VolumeOptions o;
    o.read_only = read_only;
    auto dev = iuv_exfat::open_block_device(image, read_only);
    if (env_u64("IUV_TEST_WRITE_BACK").value_or(0))
        dev = iuv_exfat::make_write_back_device(std::move(dev));
    return iuv_exfat::Volume::open(std::move(dev), o);
}

std::vector<uint8_t> digest_fill_expected(const std::vector<std::vector<uint8_t>>& inputs, uint64_t fill, uint32_t seed)
{
    std::vector<uint8_t> out(fill + 32);
    for (uint64_t j = 0; j < fill / 8; ++j) {
        const uint64_t w = (static_cast<uint64_t>(static_cast<uint32_t>(j) ^ seed) << 32) | static_cast<uint32_t>(j);
        std::memcpy(&out[j * 8], &w, 8);
    }
    uint64_t in_bytes = 0, sum = 0, xr = 0;
    for (size_t f = 0; f < inputs.size(); ++f) {
        const auto& d = inputs[f];
        in_bytes += d.size();
        for (uint64_t o = 0; o < d.size(); o += 8) {
            uint64_t w = 0;
            std::memcpy(&w, &d[o], std::min<uint64_t>(8, d.size() - o));
            const uint64_t c = w ^ o ^ (static_cast<uint64_t>(f) << 40);
            sum += c;
            xr ^= c;
        }
    }
    const uint32_t count = static_cast<uint32_t>(inputs.size());
    const uint32_t magic = 0x31474944;
    std::memcpy(&out[fill], &in_bytes, 8);
    std::memcpy(&out[fill + 8], &sum, 8);
    std::memcpy(&out[fill + 16], &xr, 8);
    std::memcpy(&out[fill + 24], &count, 4);
    std::memcpy(&out[fill + 28], &magic, 4);
    return out;
}

void verify_files(iuv_exfat::Volume& vol, const Files& files)
{
    for (const auto& [path, data] : files) {
        const auto st = vol.stat(path);
        CHECK(!st.unfinished);
        CHECK_EQ(st.size, static_cast<uint64_t>(data.size()));
        CHECK(iuv_exfat::read_file(vol, path) == data);
    }
}

std::set<std::string> listed_names(iuv_exfat::Volume& vol, const std::string& dir)
{
    std::set<std::string> names;
    for (const auto& e : vol.list(dir.empty() ? "/" : dir))
        names.insert(e.name);
    return names;
}

} // namespace iuv_test
