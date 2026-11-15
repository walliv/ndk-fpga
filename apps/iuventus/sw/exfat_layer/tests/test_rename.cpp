// test_rename.cpp: Volume::rename semantics, cut-off renames recovered, and a random rename storm against fsck.exfat
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <filesystem>
#include <map>
#include <set>
#include <system_error>

#include "test_util.hpp"

using namespace iuv_exfat;
using namespace iuv_test;

namespace {

// Mirrors the volume's case-insensitive names for the ASCII names these tests use.
std::string fold(const std::string& path)
{
    std::string k = path;
    for (auto& c : k)
        if (c >= 'a' && c <= 'z')
            c = static_cast<char>(c - 'a' + 'A');
    return k;
}

bool under(const std::string& path, const std::string& dir)
{
    return fold(path).rfind(fold(dir) + "/", 0) == 0;
}

void verify(Volume& vol, const Files& files, const std::set<std::string>& dirs)
{
    verify_files(vol, files);
    for (const auto& dir : dirs) {
        const auto got  = listed_names(vol, dir);
        const auto want = children_of(dir, files, dirs);
        if (got != want) {
            std::string msg = "listing of '" + dir + "': got";
            for (const auto& g : got)
                msg += " " + g;
            msg += "; want";
            for (const auto& w : want)
                msg += " " + w;
            throw TestFailure(msg);
        }
    }
}

void verify_image(const std::string& image, TempDir& tmp, const Files& files, const std::set<std::string>& dirs,
                  const std::string& phase)
{
    check_volume(image, tmp, phase);
    auto vol = open_volume(image, true);
    CHECK(!vol->dirty());
    verify(*vol, files, dirs);
    CHECK(vol->check().clean());
}

// Moves every model entry, a map key or a set element, at or below from to the same place below to.
template <class Model>
void move_entries(Model& m, const std::string& from, const std::string& to)
{
    constexpr bool IS_MAP = requires { typename Model::mapped_type; };
    Model moved;
    for (auto it = m.begin(); it != m.end();) {
        const std::string& path = [&]() -> const std::string& {
            if constexpr (IS_MAP)
                return it->first;
            else
                return *it;
        }();
        if (fold(path) != fold(from) && !under(path, from)) {
            ++it;
            continue;
        }
        auto node = m.extract(it++);
        if constexpr (IS_MAP)
            node.key() = to + node.key().substr(from.size());
        else
            node.value() = to + node.value().substr(from.size());
        moved.insert(std::move(node));
    }
    m.merge(moved);
}

std::string ascii_name(std::mt19937_64& rng)
{
    static const char ALNUM[] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_";
    const size_t len = rng() % 4 == 0 ? 16 + rng() % 40 : 1 + rng() % 12;
    std::string s;
    for (size_t i = 0; i < len; ++i)
        s += ALNUM[rng() % (sizeof(ALNUM) - 1)];
    return s;
}

// Random renames, creations and removals with a commit now and then; every error is predicted from the model.
void storm(std::mt19937_64& rng, const std::string& image, TempDir& tmp)
{
    make_image(image, 256 * MIB);
    Files files;
    std::set<std::string> dirs {""};
    auto vol = open_volume(image);
    auto find_file = [&](const std::string& p) {
        return std::find_if(files.begin(), files.end(), [&](const auto& f) { return fold(f.first) == fold(p); });
    };
    auto find_dir = [&](const std::string& p) {
        return std::find_if(dirs.begin(), dirs.end(), [&](const auto& d) { return fold(d) == fold(p); });
    };
    auto pick = [&](const auto& c) { return *std::next(c.begin(), static_cast<ptrdiff_t>(rng() % c.size())); };
    uint32_t renames = 0, replaced = 0, refused = 0, commits = 0;
    for (int step = 0; step < 600; ++step) {
        const uint32_t op = static_cast<uint32_t>(rng() % 20);
        if (op < 3 || files.size() < 40) {
            const std::string p = pick(dirs) + "/" + ascii_name(rng);
            if (find_file(p) != files.end() || find_dir(p) != dirs.end())
                continue;
            auto data = random_bytes(rng, rng() % 3 == 0 ? 0 : rng() % (2 * CLUSTER));
            put_file(*vol, p, data);
            files[p] = std::move(data);
        } else if (op == 3) {
            const std::string p = pick(dirs) + "/" + ascii_name(rng);
            if (find_file(p) != files.end() || find_dir(p) != dirs.end())
                continue;
            vol->make_directory(p);
            dirs.insert(p);
        } else if (op == 4) {
            const std::string victim = pick(files).first;
            vol->remove(victim);
            vol->commit();
            files.erase(victim);
        } else {
            const bool dir_move = op < 8 && dirs.size() > 1;
            std::string from = dir_move ? pick(dirs) : pick(files).first;
            if (from.empty())
                continue;
            const std::string dst_dir = pick(dirs);
            std::string to;
            switch (rng() % 8) {
            case 0:
                // A case change of the same name.
                to = from;
                for (size_t i = to.rfind('/') + 1; i < to.size(); ++i)
                    if (rng() & 1 && std::isalpha(static_cast<unsigned char>(to[i])))
                        to[i] = static_cast<char>(to[i] ^ 0x20);
                break;
            case 1:
                to = dir_move ? pick(dirs) : pick(files).first;
                break;
            default:
                to = dst_dir + "/" + ascii_name(rng);
            }
            if (to.empty())
                continue;
            std::errc want {};
            const auto tf = find_file(to);
            const auto td = find_dir(to);
            const bool same = fold(from) == fold(to);
            if (dir_move && (under(to, from) || same) && !same)
                want = std::errc::invalid_argument;
            else if (!same && tf != files.end() && dir_move)
                want = std::errc::not_a_directory;
            else if (!same && td != dirs.end() && !dir_move)
                want = std::errc::is_a_directory;
            else if (!same && td != dirs.end() && !children_of(*td, files, dirs).empty())
                want = std::errc::directory_not_empty;
            if (want != std::errc {}) {
                CHECK(throws_errc(want, [&] { vol->rename(from, to); }));
                ++refused;
                continue;
            }
            vol->rename(from, to);
            if (std::getenv("IUV_RENAME_TRACE"))
                std::printf("step %d: rename %s -> %s\n", step, from.c_str(), to.c_str());
            ++renames;
            if (!same && tf != files.end()) {
                files.erase(tf);
                ++replaced;
            }
            if (!same && td != dirs.end()) {
                dirs.erase(td);
                ++replaced;
            }
            if (dir_move) {
                move_entries(files, from, to);
                move_entries(dirs, from, to);
            } else {
                auto node = files.extract(from);
                node.key() = to;
                files.insert(std::move(node));
            }
        }
        if (std::getenv("IUV_RENAME_TRACE"))
            for (const auto& d : dirs) {
                if (listed_names(*vol, d) != children_of(d, files, dirs))
                    throw TestFailure("listing of '" + d + "' differs after step " + std::to_string(step));
            }
        if (rng() % 12 == 0) {
            vol->commit();
            ++commits;
            CHECK(!vol->dirty());
            verify(*vol, files, dirs);
        }
    }
    vol->commit();
    verify(*vol, files, dirs);
    vol->close();
    vol.reset();
    verify_image(image, tmp, files, dirs, "rename storm");
    std::printf("storm: %u renames (%u replacing), %u refused, %u commits, %zu files in %zu directories\n", renames,
                replaced, refused, commits, files.size(), dirs.size());
}

} // namespace

int main()
{
    return run_test("test_rename", [](uint64_t seed, TempDir& tmp) {
        std::mt19937_64 rng(seed);
        const std::string image = tmp.file("vol.img");
        make_image(image, 128 * MIB);
        Files files;
        std::set<std::string> dirs {"", "/sub", "/d1", "/d1/inner", "/dA", "/dB", "/full"};
        const std::string LONG = "/a_name_long_enough_to_need_more_directory_entries";
        auto vol = open_volume(image);
        for (const auto& d : dirs)
            if (!d.empty())
                vol->make_directory(d);
        for (const auto& [p, len] : std::map<std::string, uint64_t> {{"/a.bin", 3 * CLUSTER + 1}, {"/c.bin", 7},
                                                                     {"/Data.bin", CLUSTER}, {"/old.bin", 0},
                                                                     {"/target.bin", 4 * CLUSTER}, {"/d1/f", 99},
                                                                     {"/d1/inner/g", CLUSTER + 5}, {"/full/x", 1},
                                                                     {"/m1", 4}, {"/p", 5}, {"/r", 100}}) {
            files[p] = random_bytes(rng, len);
            put_file(*vol, p, files[p]);
        }

        // Same directory and a name of the same entry count: rewritten in place, so the commit has nothing to drop.
        vol->rename("/a.bin", "/b.bin");
        move_entries(files, "/a.bin", "/b.bin");
        vol->commit();
        CHECK(!vol->dirty());
        // A longer name needs new entries; the old set waits for the commit.
        vol->rename("/b.bin", LONG);
        move_entries(files, "/b.bin", LONG);
        CHECK(vol->dirty());
        CHECK(!vol->exists("/b.bin"));
        verify(*vol, files, dirs);
        vol->commit();
        CHECK(!vol->dirty());
        // A case change keeps the file and shows the new case.
        vol->rename("/data.BIN", "/DATA.bin");
        move_entries(files, "/Data.bin", "/DATA.bin");
        // Replacing a file frees its clusters at the commit.
        const uint32_t free_before = vol->info().free_clusters;
        vol->rename("/old.bin", "/target.bin");
        files["/target.bin"] = files["/old.bin"];
        files.erase("/old.bin");
        vol->commit();
        CHECK_EQ(vol->info().free_clusters, free_before + 4);
        // A directory with its contents into another directory, and onto an empty directory.
        vol->rename("/d1", "/sub/d1_moved_with_a_longer_name");
        move_entries(files, "/d1", "/sub/d1_moved_with_a_longer_name");
        move_entries(dirs, "/d1", "/sub/d1_moved_with_a_longer_name");
        vol->rename("/dA", "/dB");
        dirs.erase("/dA");
        vol->commit();
        verify(*vol, files, dirs);

        CHECK(throws_errc(std::errc::no_such_file_or_directory, [&] { vol->rename("/missing", "/x"); }));
        CHECK(throws_errc(std::errc::no_such_file_or_directory, [&] { vol->rename("/c.bin", "/nodir/x"); }));
        CHECK(throws_errc(std::errc::not_a_directory, [&] { vol->rename("/dB", "/c.bin"); }));
        CHECK(throws_errc(std::errc::is_a_directory, [&] { vol->rename("/c.bin", "/dB"); }));
        CHECK(throws_errc(std::errc::directory_not_empty, [&] { vol->rename("/dB", "/full"); }));
        CHECK(throws_errc(std::errc::invalid_argument, [&] { vol->rename("/sub", "/sub/d1_moved_with_a_longer_name/in"); }));
        CHECK(throws_errc(std::errc::invalid_argument, [&] { vol->rename("/", "/root"); }));
        CHECK(throws_errc(std::errc::invalid_argument, [&] { vol->rename("/c.bin", "/bad:name"); }));
        {
            Output busy = vol->reserve("/busy.bin", 1);
            CHECK(throws_errc(std::errc::device_or_resource_busy, [&] { vol->rename("/c.bin", "/busy.bin"); }));
            vol->abandon(busy);
            vol->make_directory("/gone");
            vol->commit();
            vol->remove("/gone");
            CHECK(throws_errc(std::errc::no_such_file_or_directory, [&] { vol->rename("/c.bin", "/gone/c.bin"); }));
            vol->commit();
            // A directory emptied by removals still staged can go in the same commit.
            vol->make_directory("/emptied");
            vol->make_directory("/emptied/sub");
            for (int k = 0; k < 3; ++k)
                put_file(*vol, "/emptied/f" + std::to_string(k), random_bytes(rng, rng() % CLUSTER));
            put_file(*vol, "/emptied/sub/g", random_bytes(rng, 1));
            vol->remove("/emptied/sub/g");
            vol->remove("/emptied/sub");
            CHECK(throws_errc(std::errc::directory_not_empty, [&] { vol->remove("/emptied"); }));
            for (int k = 0; k < 3; ++k)
                vol->remove("/emptied/f" + std::to_string(k));
            vol->remove("/emptied");
            vol->commit();
            CHECK(!vol->exists("/emptied"));
            vol->make_directory("/src_dir");
            vol->make_directory("/dst_dir");
            put_file(*vol, "/dst_dir/f", random_bytes(rng, 1));
            vol->remove("/dst_dir/f");
            vol->rename("/src_dir", "/dst_dir");
            vol->commit();
            CHECK(vol->exists("/dst_dir") && !vol->exists("/src_dir") && vol->list("/dst_dir").empty());
            vol->remove("/dst_dir");
            vol->commit();
        }
        verify(*vol, files, dirs);

        // Open outputs move with their name: a new one, and a reopened finished file that grows after the move.
        {
            Output o = vol->reserve("/out1", CLUSTER);
            const auto d = random_bytes(rng, CLUSTER - 3);
            write_extents(vol->device(), o.extents, 0, d);
            vol->rename("/out1", "/sub/out1_renamed_while_it_was_being_written");
            vol->finalize(o, d.size());
            files["/sub/out1_renamed_while_it_was_being_written"] = d;
            Output r = vol->reopen("/r");
            vol->rename("/r", "/sub/r_renamed_while_open_for_growth");
            vol->extend(r, 2 * CLUSTER);
            auto grown = files["/r"];
            const auto more = random_bytes(rng, 2 * CLUSTER);
            grown.insert(grown.end(), more.begin(), more.end());
            write_extents(vol->device(), r.extents, 0, grown);
            vol->finalize(r, grown.size());
            files.erase("/r");
            files["/sub/r_renamed_while_open_for_growth"] = grown;
            vol->commit();
        }
        // Renamed twice before a commit: out of a marked state (which commits first) and back in place.
        vol->rename("/m1", "/sub/m1_first_move_with_a_long_name");
        vol->rename("/sub/m1_first_move_with_a_long_name", "/m1_back");
        move_entries(files, "/m1", "/m1_back");
        vol->rename("/p", "/q_name_of_twenty_six_units");
        vol->rename("/q_name_of_twenty_six_units", "/p2");
        move_entries(files, "/p", "/p2");
        // Renamed, then removed before the commit.
        vol->rename("/c.bin", LONG + "_c");
        vol->remove(LONG + "_c");
        files.erase("/c.bin");
        vol->commit();
        CHECK(!vol->dirty());
        verify(*vol, files, dirs);
        vol->close();
        vol.reset();
        verify_image(image, tmp, files, dirs, "rename semantics");

        // Renames cut off before their commit: the new sets are on disk, the old sets and the replaced targets too.
        vol = open_volume(image);
        {
            for (const auto& [p, len] : std::map<std::string, uint64_t> {{"/k1", 2 * CLUSTER}, {"/k2", 0},
                                                                         {"/k3", 5}, {"/k4", CLUSTER}, {"/k5", 1}}) {
                files[p] = random_bytes(rng, len);
                put_file(*vol, p, files[p]);
            }
            files["/k6"] = random_bytes(rng, CLUSTER + 1);
            put_file(*vol, "/k6", files["/k6"]);
            vol->make_directory("/k7");
            files["/k7/h"] = random_bytes(rng, 17);
            put_file(*vol, "/k7/h", files["/k7/h"]);
            dirs.insert("/k7");
            vol->make_directory("/kd");
            vol->make_directory("/kd/sub");
            files["/kd/sub/f"] = random_bytes(rng, 3 * CLUSTER);
            put_file(*vol, "/kd/sub/f", files["/kd/sub/f"]);
            dirs.insert("/kd");
            dirs.insert("/kd/sub");
            vol->rename("/k1", LONG + "_k1");
            move_entries(files, "/k1", LONG + "_k1");
            vol->rename("/k2", "/sub/k2_empty_file_moved_to_another_directory");
            move_entries(files, "/k2", "/sub/k2_empty_file_moved_to_another_directory");
            vol->rename("/k3", "/k4");
            files["/k4"] = files["/k3"];
            files.erase("/k3");
            vol->rename("/kd", "/sub/kd_directory_moved_with_contents");
            move_entries(files, "/kd", "/sub/kd_directory_moved_with_contents");
            move_entries(dirs, "/kd", "/sub/kd_directory_moved_with_contents");
            // The freed name is taken at once, so a superseded set and a marked one share it.
            vol->rename("/k5", "/k5_moved_away_to_a_longer_name");
            vol->rename("/p2", "/k5");
            files["/k5_moved_away_to_a_longer_name"] = files["/k5"];
            files["/k5"] = files["/p2"];
            files.erase("/p2");
            vol->reserve("/unfinished", CLUSTER);
            vol->rename("/unfinished", "/sub/unfinished_output_moved_while_open");
            // New entries under names that superseded sets still hold.
            vol->rename("/k6", "/k6_moved_away_before_its_name_is_reused");
            move_entries(files, "/k6", "/k6_moved_away_before_its_name_is_reused");
            vol->reserve("/k6", CLUSTER);
            vol->rename("/k7", "/k7_moved_away_before_its_name_is_reused");
            move_entries(files, "/k7", "/k7_moved_away_before_its_name_is_reused");
            move_entries(dirs, "/k7", "/k7_moved_away_before_its_name_is_reused");
            vol->make_directory("/k7");
            dirs.insert("/k7");
            vol->flush();
            CHECK(vol->dirty());
            vol->close();
        }
        vol = open_volume(image);
        CHECK(vol->dirty());
        CHECK(throws_errc(std::errc::device_or_resource_busy, [&] { vol->rename(LONG, "/x"); }));
        const auto rep = vol->recover();
        CHECK_EQ(rep.superseded_sets, 8u);
        CHECK_EQ(rep.deleted_unfinished, 2u);
        CHECK(!vol->dirty());
        verify(*vol, files, dirs);
        vol->close();
        vol.reset();
        verify_image(image, tmp, files, dirs, "cut-off renames recovered");

        storm(rng, tmp.file("storm.img"), tmp);
    });
}
