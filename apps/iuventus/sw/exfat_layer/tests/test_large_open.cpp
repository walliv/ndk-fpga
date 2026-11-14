// test_large_open.cpp: open time and memory on a large sparse image (1 TiB unless IUV_LARGE_BYTES is set)
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#include <chrono>
#include <cstdlib>
#include <fstream>

#include "test_util.hpp"

using namespace iuv_exfat;
using namespace iuv_test;

namespace {

uint64_t rss_kib()
{
    std::ifstream f("/proc/self/status");
    std::string key;
    while (f >> key) {
        if (key == "VmRSS:") {
            uint64_t v = 0;
            f >> v;
            return v;
        }
        f.ignore(4096, '\n');
    }
    return 0;
}

void timed_open(const std::string& image, const std::string& what)
{
    const uint64_t rss0 = rss_kib();
    const auto t0 = std::chrono::steady_clock::now();
    auto vol = open_volume(image, true);
    const auto t1 = std::chrono::steady_clock::now();
    const uint64_t rss1 = rss_kib();
    const auto vi = vol->info();
    std::printf("open (%s): %.1f ms, RSS +%llu KiB, %u clusters, %u free, %u files\n", what.c_str(),
                std::chrono::duration<double, std::milli>(t1 - t0).count(), static_cast<unsigned long long>(rss1 - rss0),
                vi.cluster_count, vi.free_clusters, vi.files);
}

} // namespace

int main()
{
    return run_test("test_large_open", [](uint64_t seed, TempDir& tmp) {
        std::mt19937_64 rng(seed);
        const uint64_t bytes = env_u64("IUV_LARGE_BYTES").value_or(1ull << 40);
        const std::string image = tmp.file("large.img");
        make_image(image, bytes);
        std::printf("image %llu GiB (sparse)\n", static_cast<unsigned long long>(bytes >> 30));
        timed_open(image, "fresh");

        auto vol = open_volume(image);
        const uint64_t big = (vol->info().free_clusters / 4) * CLUSTER;
        Output o = vol->reserve("/quarter.bin", big);
        Output frag = vol->reserve("/frag.bin", CLUSTER);
        vol->extend(o, 3 * CLUSTER);
        vol->flush();
        const auto head = random_bytes(rng, 3 * CLUSTER + 17);
        write_extents(vol->device(), o.extents, 0, head);
        vol->finalize(o, big + CLUSTER);
        vol->finalize(frag, 0);
        vol->commit();
        for (int i = 0; i < 200; ++i)
            put_file(*vol, "/small" + std::to_string(i), random_bytes(rng, rng() % 2000));
        vol->close();
        vol.reset();
        timed_open(image, "with files");
        check_volume(image, tmp, "large image");
        vol = open_volume(image, true);
        const auto fe = vol->extents("/quarter.bin");
        CHECK_EQ(fe.size, big + CLUSTER);
        CHECK(fe.extents.size() >= 2);
        std::vector<uint8_t> got(head.size());
        vol->device().read(fe.extents[0].lba * LBA_BYTES, got);
        CHECK(got == head);
        CHECK(vol->check().clean());
    });
}
