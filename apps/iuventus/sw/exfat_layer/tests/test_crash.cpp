// test_crash.cpp: crash at a random device operation of reserve/run/finalize/commit, then recover()
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#include <cstdlib>
#include <filesystem>
#include <map>
#include <optional>
#include <system_error>

#include "crash_device.hpp"
#include "iuv_exfat/file_shell_model.hpp"
#include "iuv_exfat/job.hpp"
#include "test_util.hpp"

using namespace iuv_exfat;
using namespace iuv_test;

namespace {

enum class Fate { ABSENT, PRESENT, EITHER };

struct Expect {
    std::vector<uint8_t>                data;
    Fate                                fate;
    // What a rename's target held before it, which a crash ahead of the commit may leave.
    std::optional<std::vector<uint8_t>> before;
};

// Every file the session may touch, with what a crash at the current point allows.
struct Ledger {
    std::map<std::string, Expect> files;
    // Renames since the last commit; a crash leaves the data under exactly one of the two names.
    std::vector<std::pair<std::string, std::string>> moves;

    void pending(const std::string& p, std::vector<uint8_t> d) { files[p] = {std::move(d), Fate::ABSENT, {}}; }
    void committing(const std::string& p) { files[p].fate = Fate::EITHER; }
    void committed(const std::string& p) { files[p].fate = Fate::PRESENT; }
    void removed(const std::string& p) { files[p].fate = Fate::ABSENT; }

    void moving(const std::string& from, const std::string& to)
    {
        std::optional<std::vector<uint8_t>> before;
        if (auto it = files.find(to); it != files.end() && it->second.fate == Fate::PRESENT)
            before = it->second.data;
        files[to] = {files.at(from).data, Fate::EITHER, std::move(before)};
        files[from].fate = Fate::EITHER;
        moves.emplace_back(from, to);
    }

    void moved()
    {
        for (const auto& [from, to] : moves) {
            files[from].fate = Fate::ABSENT;
            files[to].fate   = Fate::PRESENT;
            files[to].before.reset();
        }
        moves.clear();
    }
};

struct Session {
    const Files& inputs;
    uint64_t     seed;
    Ledger       ledger;

    void run_job(Volume& vol, int tag, bool fail, std::mt19937_64& rng, const std::string& dir)
    {
        std::vector<std::string> names;
        for (const auto& [p, d] : inputs)
            if (p != inputs.begin()->first)
                names.push_back(p);
        const uint32_t ns = 1 + static_cast<uint32_t>(rng() % 3);
        std::vector<Output> outs;
        std::vector<std::vector<std::string>> ins(ns);
        std::vector<uint64_t> fills(ns);
        for (uint32_t s = 0; s < ns; ++s) {
            for (size_t k = 0; k < 1 + rng() % 3; ++k)
                ins[s].push_back(names[rng() % names.size()]);
            fills[s] = (rng() % (3 * CLUSTER / 64)) * 64;
            const std::string path = dir + "/job" + std::to_string(tag) + "_" + std::to_string(s);
            outs.push_back(vol.reserve(path, rng() % (fills[s] + 33)));
            std::vector<std::vector<uint8_t>> data;
            for (const auto& p : ins[s])
                data.push_back(inputs.at(p));
            ledger.pending(path, digest_fill_expected(data, fills[s], static_cast<uint32_t>(tag)));
        }
        vol.flush();
        FileShellModelOptions mo;
        mo.seed = rng();
        mo.log2_out_ring = 2;
        if (fail) {
            mo.fail_stream = 0;
            mo.fail_read = false;
            mo.fail_op = 1;
        }
        auto model = make_file_shell_model(vol.device(), mo);
        JobOptions jo;
        jo.extend_bytes = (1 + rng() % 3) * CLUSTER;
        Job job(*model, vol, jo);
        for (uint32_t s = 0; s < ns; ++s)
            job.add_stream(ins[s], outs[s], digest_fill_args(fills[s], static_cast<uint32_t>(tag)));
        job.submit();
        const auto res = job.wait();
        CHECK(res.ok != fail);
        if (res.ok)
            for (const auto& o : outs)
                ledger.committing(o.path);
        vol.commit();
        if (res.ok)
            for (const auto& o : outs)
                ledger.committed(o.path);
    }

    void run(Volume& vol)
    {
        std::mt19937_64 rng(seed);
        run_job(vol, 1, false, rng, "/out");
        auto pdata = random_bytes(rng, 1 + rng() % (2 * CLUSTER));
        ledger.pending("/out/put.bin", pdata);
        ledger.committing("/out/put.bin");
        put_file(vol, "/out/put.bin", pdata);
        ledger.committed("/out/put.bin");
        run_job(vol, 2, true, rng, "/out");
        // Renames to a longer name in another directory and onto an existing file, then of a whole directory.
        vol.make_directory("/out/mv");
        for (const std::string p : {"/out/r1", "/out/r2"}) {
            auto d = random_bytes(rng, 1 + rng() % (2 * CLUSTER));
            ledger.pending(p, d);
            ledger.committing(p);
            put_file(vol, p, d);
            ledger.committed(p);
        }
        const std::string moved_put = "/out/mv/put_moved_to_a_name_long_enough_for_new_entries.bin";
        ledger.moving("/out/put.bin", moved_put);
        vol.rename("/out/put.bin", moved_put);
        ledger.moving("/out/r1", "/out/r2");
        vol.rename("/out/r1", "/out/r2");
        vol.commit();
        ledger.moved();
        const std::string moved_dir = "/out/mv_renamed_with_a_longer_name";
        ledger.moving(moved_put, moved_dir + moved_put.substr(7));
        vol.rename("/out/mv", moved_dir);
        vol.commit();
        ledger.moved();
        const std::string victim = inputs.begin()->first;
        ledger.files[victim] = {inputs.begin()->second, Fate::EITHER, {}};
        vol.remove(victim);
        vol.commit();
        ledger.removed(victim);
        vol.make_directory("/out/d2");
        run_job(vol, 3, false, rng, "/out/d2");
        vol.close();
    }
};

} // namespace

int main()
{
    return run_test("test_crash", [](uint64_t seed, TempDir& tmp) {
        std::mt19937_64 rng(seed);
        const std::string tmpl = tmp.file("template.img");
        make_image(tmpl, 128 * MIB);
        Files inputs;
        {
            auto vol = open_volume(tmpl);
            for (int i = 0; i < 20; ++i)
                put_file(*vol, "/gap" + std::to_string(i), random_bytes(rng, 1));
            for (int i = 0; i < 20; i += 2)
                vol->remove("/gap" + std::to_string(i));
            vol->commit();
            vol->make_directory("/in");
            vol->make_directory("/out");
            for (int i = 0; i < 6; ++i) {
                const std::string p = "/in/f" + std::to_string(i);
                inputs[p] = random_bytes(rng, rng() % (3 * CLUSTER));
                put_file(*vol, p, inputs[p]);
            }
            vol->close();
        }
        const std::string image = tmp.file("crash.img");
        const int iterations = static_cast<int>(env_u64("IUV_CRASH_ITERS").value_or(40));
        uint32_t recovered_dirty = 0, deleted = 0, truncated = 0, past_eod = 0, superseded = 0;
        for (int it = 0; it < iterations; ++it) {
            const uint64_t session_seed = rng();
            // Odd iterations hold the volume's writes in a write-back cache above the crashing device, as iuv-fs does.
            const bool write_back = it % 2 == 1;
            const DeviceWrap wrap = write_back ? DeviceWrap(make_write_back_device) : nullptr;
            Session counted {inputs, session_seed, {}};
            const uint64_t total_ops = count_ops(tmpl, image, [&](Volume& v) { counted.run(v); }, wrap);
            const uint64_t crash_at = 1 + rng() % total_ops;
            Session s {inputs, session_seed, {}};
            const auto [kept, dropped] = crash_in(tmpl, image, rng(), crash_at, [&](Volume& v) { s.run(v); }, wrap);
            {
                auto vol = open_volume(image);
                if (vol->dirty()) {
                    ++recovered_dirty;
                    CHECK(throws_errc(std::errc::device_or_resource_busy, [&] { vol->reserve("/must_fail", 1); }));
                }
                const auto rep = vol->recover();
                deleted += rep.deleted_unfinished;
                truncated += rep.truncated_chains;
                past_eod += rep.entries_past_eod;
                superseded += rep.superseded_sets;
                CHECK(!vol->dirty());
                vol->close();
            }
            try {
                check_volume(image, tmp, "crash at op " + std::to_string(crash_at) + "/" + std::to_string(total_ops));
                auto vol = open_volume(image, true);
                for (const auto& [p, d] : inputs)
                    if (!s.ledger.files.count(p))
                        CHECK(read_file(*vol, p) == d);
                for (const auto& [p, e] : s.ledger.files) {
                    const bool there = vol->exists(p);
                    if (e.fate == Fate::PRESENT)
                        CHECK(there);
                    if (e.fate == Fate::ABSENT)
                        CHECK(!there);
                    if (there) {
                        CHECK(!vol->stat(p).unfinished);
                        const auto got = read_file(*vol, p);
                        CHECK(got == e.data || (e.before && got == *e.before));
                    }
                }
                for (const auto& [from, to] : s.ledger.moves)
                    CHECK(vol->exists(from) != (vol->exists(to) && read_file(*vol, to) == s.ledger.files.at(to).data));
                CHECK(vol->check().clean());
            } catch (const TestFailure&) {
                std::printf("iteration %d%s: crash at op %llu of %llu, kept %llu dropped %llu unflushed writes\n", it,
                            write_back ? " (write-back)" : "",
                            static_cast<unsigned long long>(crash_at), static_cast<unsigned long long>(total_ops),
                            static_cast<unsigned long long>(kept), static_cast<unsigned long long>(dropped));
                throw;
            }
        }
        std::printf("%d crashes: %u reopened dirty, %u unfinished outputs deleted, %u chains truncated, %u entries past EOD wiped, "
                    "%u superseded sets deleted\n",
                    iterations, recovered_dirty, deleted, truncated, past_eod, superseded);
    });
}
