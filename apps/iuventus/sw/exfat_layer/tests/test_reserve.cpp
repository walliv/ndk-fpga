// test_reserve.cpp: reserve/extend/finalize/commit/abandon and directory growth against fsck.exfat
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#include <filesystem>
#include <map>
#include <system_error>

#include "test_util.hpp"

using namespace iuv_exfat;
using namespace iuv_test;

namespace {

void verify(const std::string& image, const Files& files)
{
    auto vol = open_volume(image, true);
    CHECK(!vol->dirty());
    verify_files(*vol, files);
    CHECK(vol->check().clean());
}

void write_all(Volume& vol, const Output& out, const std::vector<uint8_t>& data)
{
    write_extents(vol.device(), out.extents, 0, data);
}

void finish(std::unique_ptr<Volume>& vol, const std::string& image, TempDir& tmp, const Files& files, const std::string& phase)
{
    vol->close();
    vol.reset();
    check_volume(image, tmp, phase);
    verify(image, files);
}

} // namespace

int main()
{
    return run_test("test_reserve", [](uint64_t seed, TempDir& tmp) {
        std::mt19937_64 rng(seed);
        const std::string image = tmp.file("vol.img");
        make_image(image, 256 * MIB);
        Files files;
        int serial = 0;
        auto fresh = [&](const std::string& dir) { return dir + "/o" + std::to_string(serial++) + "_" + random_name(rng, 8); };

        // Random rounds of reserve, write, then finalize or abandon, one group commit per round.
        auto vol = open_volume(image);
        for (int round = 0; round < 12; ++round) {
            struct Live {
                Output out;
                std::vector<uint8_t> data;
                bool keep;
            };
            std::vector<Live> live;
            const int n = 1 + static_cast<int>(rng() % 5);
            for (int i = 0; i < n; ++i) {
                const uint64_t res = rng() % (4 * CLUSTER + 1);
                Live l {vol->reserve(fresh(""), res), {}, rng() % 4 != 0};
                CHECK_EQ(l.out.reserved_bytes, (res + CLUSTER - 1) / CLUSTER * CLUSTER);
                const uint64_t fin = l.out.reserved_bytes ? rng() % (l.out.reserved_bytes + 1) : 0;
                l.data = random_bytes(rng, fin);
                live.push_back(std::move(l));
            }
            vol->flush();
            if (round == 0) {
                check_volume(image, tmp, "reservations open", true);
            }
            for (auto& l : live) {
                write_all(*vol, l.out, l.data);
                if (l.keep) {
                    vol->finalize(l.out, l.data.size());
                    files[l.out.path] = l.data;
                } else {
                    vol->abandon(l.out);
                }
            }
            vol->commit();
            CHECK(!vol->dirty());
        }
        finish(vol, image, tmp, files, "random rounds");

        // On a fresh image free space is one run, so the first extension is adjacent and the second is not.
        const std::string image2 = tmp.file("extend.img");
        make_image(image2, 64 * MIB);
        Files files2;
        vol = open_volume(image2);
        {
            Output a = vol->reserve("/extend_a", CLUSTER);
            const auto added = vol->extend(a, 2 * CLUSTER);
            CHECK_EQ(added.size(), size_t {1});
            CHECK_EQ(a.extents.size(), size_t {1});
            CHECK_EQ(vol->info().fat_chain_files, 0u);
            Output b = vol->reserve("/blocker", CLUSTER);
            CHECK_EQ(b.extents[0].lba, a.extents[0].lba + a.extents[0].count);
            const auto added2 = vol->extend(a, CLUSTER);
            CHECK_EQ(a.extents.size(), size_t {2});
            CHECK_EQ(added2[0].lba, b.extents[0].lba + b.extents[0].count);
            CHECK_EQ(vol->info().fat_chain_files, 1u);
            Output c = vol->reserve("/blocker2", CLUSTER);
            vol->extend(a, 2 * CLUSTER);
            CHECK_EQ(a.extents.size(), size_t {3});
            Output z = vol->reserve("/from_zero", 0);
            CHECK(z.extents.empty());
            vol->extend(z, 1);
            vol->extend(z, CLUSTER);
            CHECK_EQ(z.reserved_bytes, 2 * CLUSTER);
            vol->flush();
            check_volume(image2, tmp, "extended, before finalize", true);
            const auto da = random_bytes(rng, a.reserved_bytes - rng() % CLUSTER);
            write_all(*vol, a, da);
            vol->finalize(a, da.size());
            files2["/extend_a"] = da;
            const auto dz = random_bytes(rng, CLUSTER + 3);
            write_all(*vol, z, dz);
            vol->finalize(z, dz.size());
            files2["/from_zero"] = dz;
            const auto db = random_bytes(rng, CLUSTER);
            write_all(*vol, b, db);
            vol->finalize(b, db.size());
            files2["/blocker"] = db;
            vol->abandon(c);
            vol->commit();
        }
        // A FAT-chain output abandoned and a FAT-chain output truncated to zero.
        {
            Output p = vol->reserve("/p", CLUSTER);
            Output q = vol->reserve("/q", CLUSTER);
            vol->extend(p, CLUSTER);
            vol->extend(q, CLUSTER);
            vol->flush();
            vol->abandon(p);
            vol->finalize(q, 0);
            files2["/q"] = {};
            vol->commit();
        }
        finish(vol, image2, tmp, files2, "extend");
        std::filesystem::remove(image2);

        // A reservation that takes exactly every free cluster, finalized exactly full.
        vol = open_volume(image);
        {
            const uint64_t free_bytes = static_cast<uint64_t>(vol->info().free_clusters) * CLUSTER;
            Output full = vol->reserve("/full", free_bytes);
            CHECK_EQ(vol->info().free_clusters, 0u);
            CHECK(throws_errc(std::errc::no_space_on_device, [&] { vol->reserve("/one_more", 1); }));
            vol->flush();
            const auto data = random_bytes(rng, free_bytes);
            write_all(*vol, full, data);
            vol->finalize(full, data.size());
            vol->commit();
            files["/full"] = data;
            std::printf("full reservation: %llu B in %zu extents\n", static_cast<unsigned long long>(free_bytes), full.extents.size());
        }
        finish(vol, image, tmp, files, "exactly full");
        vol = open_volume(image);
        vol->remove("/full");
        vol->commit();
        files.erase("/full");
        finish(vol, image, tmp, files, "remove full");

        // Directory growth past one cluster of entries: a NoFatChain subdirectory blocked by a file, and the root.
        vol = open_volume(image);
        vol->make_directory("/big");
        Output blocker = vol->reserve("/big_blocker", CLUSTER);
        vol->finalize(blocker, 0);
        vol->commit();
        files["/big_blocker"] = {};
        const auto fat_before = vol->info().fat_chain_files;
        const uint32_t per_cluster = CLUSTER / 32;
        for (const std::string& dir : {std::string("/big"), std::string("")}) {
            uint32_t entries = 0;
            int idx = 0;
            while (entries < per_cluster + 2000) {
                std::vector<Output> batch;
                for (int k = 0; k < 64; ++k) {
                    const size_t len = 1 + rng() % 255;
                    std::string name = std::to_string(idx++) + "_";
                    while (name.size() < len)
                        name += static_cast<char>('a' + rng() % 26);
                    const std::string path = dir + "/" + name;
                    const uint64_t sz = rng() % 64 == 0 ? 1 + rng() % 1000 : 0;
                    batch.push_back(vol->reserve(path, sz));
                    entries += 2 + static_cast<uint32_t>((name.size() + 14) / 15);
                }
                vol->flush();
                for (auto& o : batch) {
                    const auto data = random_bytes(rng, o.reserved_bytes ? 1 + rng() % 700 : 0);
                    write_all(*vol, o, data);
                    vol->finalize(o, data.size());
                    files[o.path] = data;
                }
                vol->commit();
            }
        }
        CHECK(vol->info().fat_chain_files > fat_before);
        CHECK(vol->stat("/big").size > CLUSTER);
        // Delete a quarter of the directory and refill the holes.
        int removed = 0;
        for (auto it = files.begin(); it != files.end();) {
            if (it->first.rfind("/big/", 0) == 0 && rng() % 4 == 0) {
                vol->remove(it->first);
                it = files.erase(it);
                ++removed;
            } else {
                ++it;
            }
        }
        vol->commit();
        for (int k = 0; k < removed / 2; ++k) {
            const std::string path = "/big/refill" + std::to_string(k);
            const auto data = random_bytes(rng, rng() % 32 == 0 ? 1 + rng() % 600 : 0);
            put_file(*vol, path, data);
            files[path] = data;
        }
        std::printf("directory growth: /big %llu B, root files %zu\n", static_cast<unsigned long long>(vol->stat("/big").size),
                    vol->list("/").size());
        finish(vol, image, tmp, files, "directory growth");

        // A session spread over processes: reserve, close dirty, continue, then adopt and finalize each output.
        const std::string image3 = tmp.file("session.img");
        make_image(image3, 64 * MIB);
        Files files3;
        for (int k = 0; k < 2; ++k) {
            VolumeOptions o;
            o.continue_session = k > 0;
            auto v = Volume::open(open_block_device(image3), o);
            v->reserve("/s" + std::to_string(k), (1 + k) * CLUSTER + 5);
            v->flush();
            v->close();
        }
        {
            auto v = open_volume(image3);
            CHECK(v->dirty());
            CHECK(throws_errc(std::errc::device_or_resource_busy, [&] { v->reserve("/needs_recover", 1); }));
            Output s0 = v->adopt("/S0");
            CHECK_EQ(s0.reserved_bytes, 2 * CLUSTER);
            const auto d0 = random_bytes(rng, CLUSTER + 9);
            write_all(*v, s0, d0);
            v->finalize(s0, d0.size());
            v->commit();
            files3["/s0"] = d0;
            CHECK(v->dirty());
            CHECK(throws_errc(std::errc::invalid_argument, [&] { v->adopt("/s0"); }));
            v->close();
        }
        {
            VolumeOptions o;
            o.continue_session = true;
            auto v = Volume::open(open_block_device(image3), o);
            Output s1 = v->adopt("/s1");
            v->extend(s1, CLUSTER);
            const auto d1 = random_bytes(rng, s1.reserved_bytes - 3);
            write_all(*v, s1, d1);
            v->finalize(s1, d1.size());
            v->commit();
            files3["/s1"] = d1;
            CHECK(!v->dirty());
            v->close();
        }
        check_volume(image3, tmp, "session across processes");
        verify(image3, files3);

        // Reopened finished files: grow, shrink, no abandon, and a session cut off mid-growth that recover() trims back.
        const std::string image4 = tmp.file("reopen.img");
        make_image(image4, 64 * MIB);
        Files files4;
        {
            auto v = open_volume(image4);
            for (const auto& [path, len] : {std::pair<std::string, uint64_t> {"/grow", 100}, {"/shrink", 3 * CLUSTER + 7},
                                            {"/cut", CLUSTER / 2 + 3}, {"/cut_empty", 0}}) {
                files4[path] = random_bytes(rng, len);
                put_file(*v, path, files4[path]);
            }
            Output g = v->reopen("/grow");
            CHECK_EQ(g.reserved_bytes, CLUSTER);
            CHECK(throws_errc(std::errc::operation_not_permitted, [&] { v->abandon(g); }));
            CHECK(throws_errc(std::errc::device_or_resource_busy, [&] { v->reopen("/grow"); }));
            v->extend(g, 2 * CLUSTER);
            auto grown = files4["/grow"];
            const auto more = random_bytes(rng, 2 * CLUSTER + 11);
            grown.insert(grown.end(), more.begin(), more.end());
            write_all(*v, g, grown);
            v->finalize(g, grown.size());
            files4["/grow"] = grown;
            Output sh = v->reopen("/shrink");
            v->finalize(sh, 10);
            files4["/shrink"].resize(10);
            v->commit();
            CHECK(!v->dirty());
            v->close();
        }
        check_volume(image4, tmp, "reopen grow and shrink");
        verify(image4, files4);
        {
            auto v = open_volume(image4);
            for (const std::string path : {"/cut", "/cut_empty"}) {
                Output c = v->reopen(path);
                v->extend(c, 3 * CLUSTER);
                const auto written = random_bytes(rng, c.reserved_bytes);
                write_all(*v, c, written);
                // In-place writes are not undone; only the size returns to the last commit.
                files4[path].assign(written.begin(), written.begin() + static_cast<ptrdiff_t>(files4[path].size()));
            }
            v->close();
        }
        {
            auto v = open_volume(image4);
            CHECK(v->dirty());
            const auto rep = v->recover();
            CHECK_EQ(rep.trimmed_files, 2u);
            CHECK(!v->dirty());
            v->close();
        }
        check_volume(image4, tmp, "reopen cut off");
        verify(image4, files4);
    });
}
