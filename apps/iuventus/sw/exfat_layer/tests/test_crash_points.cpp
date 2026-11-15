// test_crash_points.cpp: crash inside one extend of a reopened file and inside one reserve, then reopen the volume
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#include <filesystem>
#include <system_error>

#include "crash_device.hpp"
#include "test_util.hpp"

using namespace iuv_exfat;
using namespace iuv_test;

namespace {

constexpr int ITERATIONS = 32;

} // namespace

int main()
{
    return run_test("test_crash_points", [](uint64_t seed, TempDir& tmp) {
        std::mt19937_64 rng(seed);
        const std::string tmpl  = tmp.file("template.img");
        const std::string image = tmp.file("crash.img");
        make_image(tmpl, 64 * MIB);
        const auto a_data = random_bytes(rng, 2 * CLUSTER);
        {
            auto vol = open_volume(tmpl);
            put_file(*vol, "/a", a_data);
            // Holds the cluster after /a, so the extension below turns /a into a FAT chain.
            put_file(*vol, "/b", random_bytes(rng, 1));
            vol->close();
        }

        // A reopened contiguous file grows into a FAT chain; a crash in it must leave a recoverable volume.
        auto reopen = [](Volume& v) { v.reopen("/a"); };
        auto grow   = [](Volume& v) {
            Output o = v.reopen("/a");
            v.extend(o, CLUSTER);
        };
        const uint64_t reopen_ops = count_ops(tmpl, image, reopen);
        const uint64_t extend_ops = count_ops(tmpl, image, grow) - reopen_ops;
        for (int it = 0; it < ITERATIONS; ++it) {
            // Even iterations crash at the closing flush, where every write of the extension is still volatile.
            const uint64_t op = it % 2 == 0 ? extend_ops : 1 + rng() % extend_ops;
            crash_in(tmpl, image, rng(), reopen_ops + op, grow);
            auto vol = open_volume(image);
            try {
                vol->recover();
            } catch (const std::exception& e) {
                throw TestFailure(std::string("extend crash at op ") + std::to_string(op) + "/" + std::to_string(extend_ops) +
                                  ": recover() failed: " + e.what());
            }
            CHECK(read_file(*vol, "/a") == a_data);
            CHECK(vol->check().clean());
            vol->close();
            vol.reset();
            check_volume(image, tmp, "extend crash at op " + std::to_string(op));
        }

        // A reserve cut off mid-way may leave its entry without its bitmap bits; adopt() must not let the volume reuse them.
        auto take    = [](Volume& v) {
            v.reserve("/r", 2 * CLUSTER + 1);
            v.flush();
        };
        const uint64_t reserve_ops = count_ops(tmpl, image, take);
        uint32_t adopted = 0;
        for (int it = 0; it < ITERATIONS; ++it) {
            const uint64_t op = it % 2 == 0 ? reserve_ops : 1 + rng() % reserve_ops;
            crash_in(tmpl, image, rng(), op, take);
            {
                auto vol = open_volume(image);
                if (vol->exists("/r") && vol->stat("/r").unfinished) {
                    ++adopted;
                    Output r = vol->adopt("/r");
                    const bool refused = throws_errc(std::errc::device_or_resource_busy, [&] { vol->reserve("/other", 2 * CLUSTER); });
                    if (!refused)
                        CHECK_EQ(vol->check().cross_linked, 0u);
                }
            }
            auto vol = open_volume(image);
            vol->recover();
            CHECK(read_file(*vol, "/a") == a_data);
            CHECK(vol->check().clean());
            vol->close();
            vol.reset();
            check_volume(image, tmp, "reserve crash at op " + std::to_string(op));
        }
        std::printf("%d extend crashes over %llu ops, %d reserve crashes over %llu ops, %u adopted\n", ITERATIONS,
                    static_cast<unsigned long long>(extend_ops), ITERATIONS, static_cast<unsigned long long>(reserve_ops),
                    adopted);
    });
}
