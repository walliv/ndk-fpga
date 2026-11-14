// test_open_put.cpp: open/ls/extents/get on images populated by put, including fragmented free space
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#include <algorithm>
#include <cctype>
#include <functional>
#include <map>
#include <set>
#include <system_error>

#include "iuv_exfat/util.hpp"
#include "test_util.hpp"

using namespace iuv_exfat;
using namespace iuv_test;

namespace {

struct Expected {
    uint64_t size;
    uint64_t seed;
};

std::vector<uint8_t> content(const Expected& e)
{
    std::mt19937_64 r(e.seed);
    return random_bytes(r, e.size);
}

std::string flip_case(std::string s)
{
    for (auto& c : s)
        if (std::isalpha(static_cast<unsigned char>(c)) && (static_cast<unsigned char>(c) < 0x80))
            c = static_cast<char>(std::islower(static_cast<unsigned char>(c)) ? std::toupper(c) : std::tolower(c));
    return s;
}

void verify(const std::string& image, const std::map<std::string, Expected>& files, const std::set<std::string>& dirs)
{
    auto vol = open_volume(image, true);
    CHECK(!vol->dirty());
    const auto vi = vol->info();
    std::vector<std::pair<uint64_t, uint64_t>> spans;
    for (const auto& [path, e] : files) {
        const auto st = vol->stat(flip_case(path));
        CHECK(!st.is_dir);
        CHECK(!st.unfinished);
        CHECK_EQ(st.size, e.size);
        const auto fe = vol->extents(path);
        CHECK_EQ(fe.size, e.size);
        CHECK_EQ(fe.valid_size, e.size);
        uint64_t lbas = 0;
        for (const auto& x : fe.extents) {
            CHECK(x.count >= 1);
            CHECK(x.lba * LBA_BYTES >= vi.heap_offset_bytes);
            CHECK((x.lba * LBA_BYTES - vi.heap_offset_bytes) % CLUSTER == 0);
            lbas += x.count;
            spans.emplace_back(x.lba, x.lba + x.count);
        }
        CHECK_EQ(lbas, div_ceil<uint64_t>(e.size, LBA_BYTES));
        CHECK(read_file(*vol, path) == content(e));
    }
    std::sort(spans.begin(), spans.end());
    for (size_t i = 1; i < spans.size(); ++i)
        CHECK(spans[i].first >= spans[i - 1].second);
    for (const auto& d : dirs)
        CHECK(listed_names(*vol, d) == children_of(d, files, dirs));
    CHECK(vol->check().clean());
}

} // namespace

int main()
{
    return run_test("test_open_put", [](uint64_t seed, TempDir& tmp) {
        std::mt19937_64 rng(seed);
        const std::string image = tmp.file("vol.img");
        make_image(image, 256 * MIB);
        std::map<std::string, Expected> files;
        std::set<std::string> dirs {""};
        std::vector<std::string> dir_list {""};

        auto vol = open_volume(image);
        const int ndirs = 3 + static_cast<int>(rng() % 8);
        for (int i = 0; i < ndirs; ++i) {
            const std::string parent = dir_list[rng() % dir_list.size()];
            const std::string path = parent + "/" + random_name(rng, 20);
            if (throws_errc(std::errc::file_exists, [&] { vol->make_directory(path); }))
                continue;
            dirs.insert(path);
            dir_list.push_back(path);
        }
        const uint64_t fixed_sizes[] = {0, 1, 511, 512, CLUSTER, 3 * CLUSTER, CLUSTER + 1, 4095, 4096, 4097};
        uint64_t budget = 100 * MIB;
        const int nfiles = 15 + static_cast<int>(rng() % 20);
        for (int i = 0; i < nfiles; ++i) {
            const uint64_t size = i < static_cast<int>(std::size(fixed_sizes)) ? fixed_sizes[i]
                                                                                : rng() % std::min<uint64_t>(budget, 6 * CLUSTER);
            const std::string path = dir_list[rng() % dir_list.size()] + "/" + random_name(rng);
            const Expected e {size, rng()};
            if (throws_errc(std::errc::file_exists, [&] { put_file(*vol, path, content(e)); }))
                continue;
            files[path] = e;
            budget -= std::min(budget, (size + CLUSTER - 1) / CLUSTER * CLUSTER);
        }
        vol->close();
        vol.reset();
        check_volume(image, tmp, "populate");
        verify(image, files, dirs);

        // Fill, delete every other filler, then a file that needs several free runs.
        vol = open_volume(image);
        std::vector<std::string> fillers;
        for (int i = 0;; ++i) {
            const uint64_t size = (1 + rng() % 3) * CLUSTER - rng() % 600;
            const std::string path = "/fill" + std::to_string(i);
            const Expected e {size, rng()};
            if (throws_errc(std::errc::no_space_on_device, [&] { put_file(*vol, path, content(e)); }))
                break;
            files[path] = e;
            fillers.push_back(path);
        }
        CHECK(fillers.size() > 10);
        CHECK(vol->info().free_clusters < 3);
        vol->close();
        vol.reset();
        check_volume(image, tmp, "fill");

        vol = open_volume(image);
        for (size_t i = 0; i < fillers.size(); i += 2) {
            vol->remove(fillers[i]);
            files.erase(fillers[i]);
        }
        vol->commit();
        CHECK(!vol->dirty());
        vol->close();
        vol.reset();
        check_volume(image, tmp, "delete every other");
        verify(image, files, dirs);

        vol = open_volume(image);
        const auto before = vol->info();
        const uint64_t big = (before.free_clusters - 1) * CLUSTER - rng() % CLUSTER;
        const Expected eb {big, rng()};
        put_file(*vol, "/fragmented.bin", content(eb));
        files["/fragmented.bin"] = eb;
        const auto fe = vol->extents("/fragmented.bin");
        CHECK(fe.extents.size() > 1);
        CHECK(vol->info().fat_chain_files > before.fat_chain_files);
        vol->close();
        vol.reset();
        check_volume(image, tmp, "fragmented allocation");
        verify(image, files, dirs);
        std::printf("files %zu dirs %zu fragmented extents %zu\n", files.size(), dirs.size(), fe.extents.size());

        // Geometry: a bare image works, a misaligned heap and a stripe that differs from the cluster are refused.
        const std::string bare = tmp.file("bare.img");
        make_bare_image(bare, 64 * MIB, "1M");
        {
            auto bv = open_volume(bare);
            CHECK_EQ(bv->info().partition_offset_bytes, uint64_t {0});
            const auto d = random_bytes(rng, 3 * CLUSTER + 5);
            put_file(*bv, "/bare.bin", d);
            CHECK(read_file(*bv, "/bare.bin") == d);
        }
        check_volume(bare, tmp, "bare image");
        CHECK(throws_errc(std::errc::invalid_argument, [&] {
            VolumeOptions o;
            o.drives = 8;
            Volume::open(open_block_device(image), o);
        }));
        make_bare_image(bare, 64 * MIB, "4K");
        CHECK(throws_errc(std::errc::invalid_argument, [&] { open_volume(bare); }));
    });
}
