// test_commit_error.cpp: one failed write inside commit() or rename(), then later calls refused and recover() on the next open
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#include <filesystem>
#include <system_error>

#include "flaky_device.hpp"
#include "test_util.hpp"

using namespace iuv_exfat;
using namespace iuv_test;

int main()
{
    return run_test("test_commit_error", [](uint64_t seed, TempDir& tmp) {
        std::mt19937_64 rng(seed);
        const std::string tmpl  = tmp.file("template.img");
        const std::string image = tmp.file("vol.img");
        for (int it = 0; it < 12; ++it) {
            make_image(tmpl, 64 * MIB);
            Files files;
            const int nfiles = 3 + static_cast<int>(rng() % 6);
            {
                auto vol = open_volume(tmpl);
                for (int i = 0; i < nfiles; ++i) {
                    const std::string p = "/f" + std::to_string(i);
                    files[p] = random_bytes(rng, rng() % (3 * CLUSTER));
                    put_file(*vol, p, files[p]);
                }
                vol->close();
            }
            const std::string keep = "/f0";
            std::vector<std::string> victims;
            for (const auto& [p, d] : files)
                if (p != keep)
                    victims.push_back(p);

            // A dry run counts the commit's writes, so the failure can hit any of them.
            uint64_t commit_writes = 0;
            for (int pass = 0; pass < 2; ++pass) {
                std::filesystem::copy_file(tmpl, image, std::filesystem::copy_options::overwrite_existing);
                auto dev = std::make_unique<FlakyDevice>(open_block_device(image));
                FlakyDevice* fd = dev.get();
                auto vol = Volume::open(std::move(dev));
                for (const auto& p : victims)
                    vol->remove(p);
                if (pass == 0) {
                    fd->arm(0);
                    vol->commit();
                    commit_writes = fd->writes();
                    CHECK(commit_writes >= victims.size());
                    continue;
                }
                const uint64_t k = 1 + rng() % commit_writes;
                fd->arm(k);
                CHECK(throws_errc(std::errc::io_error, [&] { vol->commit(); }));
                // Repeating the half-applied operations would touch freed nodes; every write is refused instead.
                CHECK(throws_errc(std::errc::io_error, [&] { vol->commit(); }));
                CHECK(throws_errc(std::errc::io_error, [&] { vol->reserve("/new", 1); }));
                CHECK(throws_errc(std::errc::io_error, [&] { vol->remove(keep); }));
                CHECK(read_file(*vol, keep) == files[keep]);
                vol->close();
                std::printf("iteration %d: write %llu of %llu failed, %zu removals staged\n", it,
                            static_cast<unsigned long long>(k), static_cast<unsigned long long>(commit_writes),
                            victims.size());
            }

            auto vol = open_volume(image);
            CHECK(vol->dirty());
            vol->recover();
            CHECK(!vol->dirty());
            for (const auto& [p, d] : files)
                if (vol->exists(p))
                    CHECK(read_file(*vol, p) == d);
            CHECK(vol->exists(keep));
            CHECK(vol->check().clean());
            vol->close();
            vol.reset();
            check_volume(image, tmp, "recovered after a failed commit, iteration " + std::to_string(it));
        }

        // A failed entry write of an in-place rename leaves the set half edited in memory; later changes must be refused.
        for (int it = 0; it < 4; ++it) {
            const std::string from = "/a_name_long_enough_for_two_name_entries_" + std::to_string(it);
            const std::string to   = "/s" + std::to_string(it);
            const auto data = random_bytes(rng, 1 + rng() % CLUSTER);
            make_image(tmpl, 64 * MIB);
            {
                auto vol = open_volume(tmpl);
                put_file(*vol, from, data);
                vol->close();
            }
            uint64_t rename_writes = 0;
            for (int pass = 0; pass < 2; ++pass) {
                std::filesystem::copy_file(tmpl, image, std::filesystem::copy_options::overwrite_existing);
                auto dev = std::make_unique<FlakyDevice>(open_block_device(image));
                FlakyDevice* fd = dev.get();
                auto vol = Volume::open(std::move(dev));
                fd->arm(pass == 0 ? 0 : rename_writes);
                if (pass == 0) {
                    vol->rename(from, to);
                    rename_writes = fd->writes();
                    continue;
                }
                CHECK(throws_errc(std::errc::io_error, [&] { vol->rename(from, to); }));
                const bool refused = throws_errc(std::errc::io_error, [&] {
                    Output o = vol->reopen(from);
                    vol->extend(o, CLUSTER);
                    vol->finalize(o, data.size());
                    vol->commit();
                });
                CHECK(refused);
                vol->close();
            }
            auto vol = open_volume(image);
            if (vol->dirty())
                vol->recover();
            CHECK(vol->exists(from) != vol->exists(to));
            CHECK(read_file(*vol, vol->exists(from) ? from : to) == data);
            CHECK(vol->check().clean());
            vol->close();
            vol.reset();
            check_volume(image, tmp, "failed rename write, iteration " + std::to_string(it));
        }

        // A write-back page whose fill read failed must not stay cached, or a retried partial write flushes garbage around it.
        const std::string raw = tmp.file("raw.img");
        const auto original = random_bytes(rng, MIB);
        {
            std::FILE* f = std::fopen(raw.c_str(), "wb");
            CHECK(f && std::fwrite(original.data(), 1, original.size(), f) == original.size());
            std::fclose(f);
        }
        auto expected = original;
        {
            auto dev = std::make_unique<FlakyDevice>(open_block_device(raw));
            FlakyDevice* fd = dev.get();
            auto wb = make_write_back_device(std::move(dev));
            const uint64_t off = 4096 * (1 + rng() % 200) + 1 + rng() % 4000;
            const auto patch = random_bytes(rng, 1 + rng() % 64);
            fd->fail_next_read();
            CHECK(throws_errc(std::errc::io_error, [&] { wb->write(off, patch); }));
            wb->write(off, patch);
            wb->flush();
            std::copy(patch.begin(), patch.end(), expected.begin() + static_cast<ptrdiff_t>(off));
        }
        std::vector<uint8_t> got(MIB);
        open_block_device(raw, true)->read(0, got);
        CHECK(got == expected);
    });
}
