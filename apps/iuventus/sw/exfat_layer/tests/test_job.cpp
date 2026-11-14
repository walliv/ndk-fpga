// test_job.cpp: Job end to end against FileShellModel, with NEED_SPACE, ring wrap and injected I/O failures
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#include <array>
#include <chrono>
#include <map>
#include <optional>
#include <system_error>

#include "iuv_exfat/file_shell_model.hpp"
#include "iuv_exfat/job.hpp"
#include "test_util.hpp"

using namespace iuv_exfat;
using namespace iuv_test;

namespace {

// Inputs land in fragmented free space so most of them are multi-extent FAT chains.
Files make_inputs(Volume& vol, std::mt19937_64& rng)
{
    std::vector<std::string> blockers;
    for (int i = 0; vol.info().free_clusters > 0; ++i) {
        const std::string p = "/blk" + std::to_string(i);
        put_file(vol, p, random_bytes(rng, 1 + rng() % 4096));
        blockers.push_back(p);
    }
    for (size_t i = 0; i < blockers.size(); i += 2)
        vol.remove(blockers[i]);
    vol.commit();
    vol.make_directory("/in");
    Files inputs;
    const uint64_t sizes[] = {0, 1, 7, 8, 511, 512, 513, CLUSTER, CLUSTER + 77, 3 * CLUSTER - 5};
    for (int i = 0; i < 24; ++i) {
        const uint64_t size = i < 10 ? sizes[i] : rng() % (4 * CLUSTER);
        const std::string p = "/in/f" + std::to_string(i) + "_" + random_name(rng, 6);
        if (inputs.count(p))
            continue;
        auto data = random_bytes(rng, size);
        put_file(vol, p, data);
        inputs[p] = std::move(data);
    }
    for (size_t i = 1; i < blockers.size(); i += 2)
        vol.remove(blockers[i]);
    vol.commit();
    return inputs;
}

FileShellModelOptions model_options(std::mt19937_64& rng)
{
    FileShellModelOptions mo;
    mo.seed = rng();
    if (rng() % 2) {
        mo.log2_in_ring = 2 + static_cast<uint32_t>(rng() % 3);
        mo.log2_out_ring = 1 + static_cast<uint32_t>(rng() % 3);
    }
    mo.in_window = 1 + static_cast<uint32_t>(rng() % 40);
    mo.max_ops_per_poll = 1 + static_cast<uint32_t>(rng() % 12);
    return mo;
}

// Freezes the shell after `after` STATUS polls by answering BUSY without stepping it, until the next CTRL write.
class StallBus final : public MiBus {
public:
    StallBus(MiBus& inner, uint64_t after) : inner_(inner), after_(after) {}

    uint32_t read32(uint64_t offset) override
    {
        if (offset == 0x04 && !released_ && ++polls_ > after_)
            return 1;
        return inner_.read32(offset);
    }
    void write32(uint64_t offset, uint32_t value) override
    {
        if (offset == 0x00 && polls_ > after_)
            released_ = true;
        inner_.write32(offset, value);
    }

private:
    MiBus&   inner_;
    uint64_t after_;
    uint64_t polls_    = 0;
    bool     released_ = false;
};

// Counts reads per register offset.
class CountBus final : public MiBus {
public:
    explicit CountBus(MiBus& inner) : inner_(inner) {}

    uint32_t read32(uint64_t offset) override
    {
        ++reads[offset];
        return inner_.read32(offset);
    }
    void write32(uint64_t offset, uint32_t value) override { inner_.write32(offset, value); }

    std::map<uint64_t, uint64_t> reads;

private:
    MiBus& inner_;
};

using Entry = std::array<uint32_t, 4>;
using Ring  = std::vector<Entry>;

constexpr uint32_t LAST_BIT = 1u << 31;
constexpr uint32_t FORMAT   = 1u << 8;
constexpr uint32_t IN_LIST  = 1u << 2;
constexpr uint32_t STRIPE_DEFAULT = 2 | (8 << 8);

struct RawResult {
    uint32_t status = 0;
    std::array<uint32_t, 2> stream_status {};
    std::array<uint32_t, 2> err_info {};
};

// Drives two streams straight through the register map, bypassing Job, so malformed entries reach the model.
RawResult run_raw(BlockDevice& dev, const std::array<Ring, 2>& in, const std::array<Ring, 2>& out, uint32_t stripe,
                  const std::array<uint64_t, 2>& fill, uint64_t hbm_poll = 0)
{
    FileShellModelOptions mo;
    mo.fail_hbm_poll = hbm_poll;
    auto m = make_file_shell_model(dev, mo);
    m->write32(0x00, 4);
    for (uint32_t s = 0; s < 2; ++s) {
        for (size_t e = 0; e < in[s].size(); ++e)
            for (uint32_t w = 0; w < 4; ++w)
                m->write32(0x1000000 + s * 0x100000 + e * 16 + 4 * w, in[s][e][w]);
        for (size_t e = 0; e < out[s].size(); ++e)
            for (uint32_t w = 0; w < 4; ++w)
                m->write32(0x800000 + s * 0x40000 + e * 16 + 4 * w, out[s][e][w]);
        m->write32(0x108 + s * 0x40, static_cast<uint32_t>(in[s].size()));
        m->write32(0x110 + s * 0x40, static_cast<uint32_t>(out[s].size()));
        m->write32(0x1000 + s * 0x200, static_cast<uint32_t>(fill[s]));
        m->write32(0x1004 + s * 0x200, static_cast<uint32_t>(fill[s] >> 32));
        m->write32(0x1008 + s * 0x200, 5);
    }
    m->write32(0x18, stripe);
    m->write32(0x08, 3);
    m->write32(0x00, 1);
    RawResult r;
    for (int i = 0; i < 100000 && ((r.status = m->read32(0x04)) & 1); ++i) {
    }
    for (uint32_t s = 0; s < 2; ++s) {
        r.stream_status[s] = m->read32(0x120 + s * 0x40);
        r.err_info[s] = m->read32(0x124 + s * 0x40);
    }
    if (hbm_poll == 0)
        return r;
    CHECK_EQ(m->injected_stream_mask(), 3u);
    return r;
}

// FORMAT, ABORT and HBM error sources, each with the offending entry index the RTL reports.
void raw_error_cases(Volume& vol, uint64_t in_lba)
{
    Output scratch = vol.reserve("/raw_scratch", 4 * CLUSTER);
    vol.flush();
    const uint64_t o0 = scratch.extents[0].lba;
    const Ring good_in {{4096, 0, 0, 1}, {static_cast<uint32_t>(in_lba), static_cast<uint32_t>(in_lba >> 32), 8, LAST_BIT}};
    const Ring good_out0 {{static_cast<uint32_t>(o0), static_cast<uint32_t>(o0 >> 32), 1, 0},
                          {static_cast<uint32_t>(o0 + 1), static_cast<uint32_t>(o0 >> 32), 1023, 0}};
    const Ring good_out1 {{static_cast<uint32_t>(o0 + 2048), static_cast<uint32_t>(o0 >> 32), 2048, 0}};
    const std::array<uint64_t, 2> fill {64 * 1024, 64 * 1024};
    const uint32_t lba = static_cast<uint32_t>(in_lba);

    auto ok = run_raw(vol.device(), {good_in, good_in}, {good_out0, good_out1}, STRIPE_DEFAULT, fill);
    CHECK_EQ(ok.status & 7, 2u);
    ok = run_raw(vol.device(), {good_in, good_in}, {good_out0, good_out1}, 1 | (7 << 8), fill);
    CHECK_EQ(ok.status & 7, 2u);

    struct InCase {
        const char* what;
        Ring ring;
        uint32_t index;
    };
    const InCase in_cases[] = {
        {"EXTENT before FILE", {{lba, 0, 8, LAST_BIT}}, 1},
        {"COUNT 0", {{4096, 0, 0, 1}, {lba, 0, 0, LAST_BIT}}, 2},
        {"unknown TYPE", {{4096, 0, 0, 1}, {lba, 0, 8, 2 | LAST_BIT}}, 2},
        {"reserved word 3 bits", {{4096, 0, 0, 1 | 0x10}, {lba, 0, 8, LAST_BIT}}, 1},
        {"LBA bits 31:16 of word 1", {{4096, 0, 0, 1}, {lba, 0x10000, 8, LAST_BIT}}, 2},
        {"SIZE >= 2^48", {{0, 0x10000, 0, 1}, {lba, 0, 8, LAST_BIT}}, 1},
        {"next FILE before the extents cover SIZE", {{4096, 0, 0, 1}, {lba, 0, 1, 0}, {0, 0, 1, 1 | LAST_BIT}}, 3},
        {"short LAST extent", {{4096, 0, 0, 1}, {lba, 0, 7, LAST_BIT}}, 2},
        {"FILE with LAST and nonzero SIZE", {{1, 0, 0, 1 | LAST_BIT}}, 1},
    };
    for (const auto& c : in_cases) {
        const auto r = run_raw(vol.device(), {c.ring, good_in}, {good_out0, good_out1}, STRIPE_DEFAULT, fill);
        if ((r.status & 4) == 0 || r.err_info[0] != (FORMAT | IN_LIST | (c.index << 16)) || (r.stream_status[1] & 8))
            throw TestFailure(std::string("input FORMAT case '") + c.what + "': ERR_INFO " + std::to_string(r.err_info[0]));
    }
    struct OutCase {
        const char* what;
        Entry bad;
    };
    const uint32_t ob = static_cast<uint32_t>(o0 + 1);
    const OutCase out_cases[] = {
        {"TYPE not EXTENT", {ob, 0, 1023, 1}},
        {"LAST set", {ob, 0, 1023, LAST_BIT}},
        {"reserved bits", {ob, 0, 1023, 0x100}},
        {"LBA bits 31:16 of word 1", {ob, 0x20000, 1023, 0}},
        {"COUNT 0", {ob, 0, 0, 0}},
    };
    for (const auto& c : out_cases) {
        const Ring bad_out {good_out0[0], c.bad};
        const auto r = run_raw(vol.device(), {good_in, good_in}, {bad_out, good_out1}, STRIPE_DEFAULT, fill);
        if ((r.status & 4) == 0 || r.err_info[0] != (FORMAT | (2u << 16)) || (r.stream_status[1] & 8))
            throw TestFailure(std::string("output FORMAT case '") + c.what + "': ERR_INFO " + std::to_string(r.err_info[0]));
    }
    for (const uint32_t stripe : {2u | (9u << 8), 3u | (8u << 8)}) {
        const auto r = run_raw(vol.device(), {good_in, good_in}, {good_out0, good_out1}, stripe, fill);
        CHECK((r.status & 4) != 0);
        CHECK_EQ(r.err_info[0], FORMAT);
        CHECK_EQ(r.err_info[1], FORMAT);
    }
    const auto bad_fill = run_raw(vol.device(), {good_in, good_in}, {good_out0, good_out1}, STRIPE_DEFAULT, {100, 64});
    CHECK((bad_fill.status & 4) != 0);
    CHECK_EQ(bad_fill.err_info[0], FORMAT);
    CHECK_EQ(bad_fill.stream_status[1] & 8, 0u);

    const auto hbm = run_raw(vol.device(), {good_in, good_in}, {good_out0, good_out1}, STRIPE_DEFAULT, fill, 2);
    CHECK((hbm.status & 4) != 0);
    CHECK_EQ(hbm.err_info[0], 3u << 8);
    CHECK_EQ(hbm.err_info[1], 3u << 8);

    auto m = make_file_shell_model(vol.device());
    m->write32(0x00, 4);
    for (uint32_t w = 0; w < 4; ++w)
        m->write32(0x1000000 + 4 * w, good_in[0][w]);
    m->write32(0x108, 1);
    m->write32(0x1000, 1u << 20);
    m->write32(0x18, STRIPE_DEFAULT);
    m->write32(0x08, 1);
    m->write32(0x00, 1);
    m->write32(0x00, 2);
    CHECK((m->read32(0x04) & 4) != 0);
    CHECK_EQ(m->read32(0x124), 2u << 8);

    CHECK(describe_err_info(3u << 8).find("HBM") != std::string::npos);
    CHECK(describe_err_info(FORMAT | IN_LIST | (7u << 16)).find("input list entry 7") != std::string::npos);
    CHECK(describe_err_info(FORMAT | (2u << 16)).find("output ring entry 2") != std::string::npos);
    // ERR_INFO carries the entry number modulo 65536; index 0 is START only without the input list bit.
    CHECK(describe_err_info(FORMAT | IN_LIST).find("65536") != std::string::npos);
    CHECK(describe_err_info(FORMAT | IN_LIST).find("START") == std::string::npos);
    CHECK(describe_err_info(FORMAT).find("START") != std::string::npos);
    CHECK(describe_err_info(FORMAT).find("65536") != std::string::npos);
    CHECK(describe_err_info(2u).find("out of range") != std::string::npos);
    vol.abandon(scratch);
    vol.commit();
}

} // namespace

int main()
{
    return run_test("test_job", [](uint64_t seed, TempDir& tmp) {
        std::mt19937_64 rng(seed);
        const std::string image = tmp.file("vol.img");
        make_image(image, 256 * MIB);
        auto vol = open_volume(image);
        const Files inputs = make_inputs(*vol, rng);
        std::vector<std::string> names;
        for (const auto& [p, d] : inputs)
            names.push_back(p);
        uint32_t multi_extent = 0;
        for (const auto& n : names)
            multi_extent += vol->extents(n).extents.size() > 1;
        CHECK(multi_extent >= 3);
        std::string biggest = names[0];
        for (const auto& n : names)
            if (inputs.at(n).size() > inputs.at(biggest).size())
                biggest = n;
        raw_error_cases(*vol, vol->extents(biggest).extents[0].lba);

        {
            Output o = vol->reserve("/unflushed", CLUSTER);
            auto m = make_file_shell_model(vol->device());
            Job j(*m, *vol);
            j.add_stream({names[0]}, o, digest_fill_args(0, 0));
            CHECK(throws_errc(std::errc::operation_not_permitted, [&] { j.submit(); }));
            vol->abandon(o);
            vol->commit();
        }
        {
            // The timeout bounds a stall, not the job: a job running past it while it progresses completes.
            using namespace std::chrono_literals;
            JobOptions jo;
            jo.timeout       = 20ms;
            jo.poll_interval = 2ms;
            FileShellModelOptions mo;
            mo.seed             = rng();
            mo.max_ops_per_poll = 1;
            Output slow = vol->reserve("/slow", 2 * CLUSTER);
            vol->flush();
            auto m = make_file_shell_model(vol->device(), mo);
            Job j(*m, *vol, jo);
            j.add_stream({biggest, biggest}, slow, digest_fill_args(CLUSTER, 6));
            const auto t0 = std::chrono::steady_clock::now();
            j.submit();
            const auto res = j.wait();
            const auto took = std::chrono::steady_clock::now() - t0;
            if (!res.ok)
                throw TestFailure("progressing job failed: " + res.error);
            CHECK(took > 2 * jo.timeout);
            vol->commit();
            CHECK(read_file(*vol, "/slow") == digest_fill_expected({inputs.at(biggest), inputs.at(biggest)}, CLUSTER, 6));

            Output stuck = vol->reserve("/stuck", 2 * CLUSTER);
            vol->flush();
            auto m2 = make_file_shell_model(vol->device(), mo);
            StallBus bus(*m2, 3);
            Job j2(bus, *vol, jo);
            j2.add_stream({biggest}, stuck, digest_fill_args(CLUSTER, 7));
            j2.submit();
            const auto res2 = j2.wait();
            CHECK(!res2.ok);
            CHECK(res2.error.find("timed out") != std::string::npos);
            vol->commit();
            CHECK(!vol->exists("/stuck"));
            // A long job backs off to about one STATUS poll per millisecond and reads its progress counters rarely.
            JobOptions jf;
            jf.poll_interval = 50us;
            Output paced = vol->reserve("/paced", 2 * CLUSTER);
            vol->flush();
            auto m3 = make_file_shell_model(vol->device(), mo);
            CountBus counted(*m3);
            Job j3(counted, *vol, jf);
            j3.add_stream({biggest, biggest}, paced, digest_fill_args(CLUSTER, 8));
            const auto t3 = std::chrono::steady_clock::now();
            j3.submit();
            CHECK(j3.wait().ok);
            const auto took3 = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - t3);
            const uint64_t polls = counted.reads[0x04];
            CHECK(took3 > 20ms);
            CHECK(polls * 400 < static_cast<uint64_t>(took3.count()));
            CHECK(counted.reads[0x128] <= 2 + static_cast<uint64_t>(took3.count()) / 100000);
            vol->commit();
            vol->remove("/paced");
            vol->remove("/slow");
            vol->commit();
            std::printf("paced job: %llu STATUS polls in %lld us\n", static_cast<unsigned long long>(polls),
                        static_cast<long long>(took3.count()));
            std::printf("progressing job ran %lld ms against a %lld ms timeout\n",
                        static_cast<long long>(std::chrono::duration_cast<std::chrono::milliseconds>(took).count()),
                        static_cast<long long>(jo.timeout.count()));
        }

        Files outputs;
        int job_no = 0;
        uint32_t total_ext = 0;
        // Jobs 10..15 inject a read then a write failure with each NVMe code 1..3; job 16 an HBM error.
        for (int iter = 0; iter < 17; ++iter) {
            const int kind = iter < 10 ? 0 : (iter < 13 ? 1 : (iter < 16 ? 2 : 3));
            const uint32_t code = static_cast<uint32_t>((iter - 10) % 3 + 1);
            const uint32_t nstreams = 1 + static_cast<uint32_t>(rng() % MAX_STREAMS);
            struct S {
                std::vector<std::string> in;
                Output out;
                uint64_t fill;
                uint32_t seed;
            };
            std::vector<S> ss;
            for (uint32_t s = 0; s < nstreams; ++s) {
                S x;
                const size_t nin = 1 + rng() % 5;
                for (size_t k = 0; k < nin; ++k)
                    x.in.push_back(names[rng() % names.size()]);
                x.fill = (rng() % (2 * CLUSTER / 64)) * 64;
                x.seed = static_cast<uint32_t>(rng());
                const uint64_t need = x.fill + 32;
                const uint64_t res = rng() % 3 == 0 ? 0 : rng() % (need + 1);
                x.out = vol->reserve("/job" + std::to_string(job_no) + "_s" + std::to_string(s), res);
                ss.push_back(std::move(x));
            }
            vol->flush();
            auto mo = model_options(rng);
            uint32_t victim = static_cast<uint32_t>(rng() % nstreams);
            if (kind == 1) {
                ss[victim].in.push_back(biggest);
                mo.fail_stream = static_cast<int>(victim);
                mo.fail_read = true;
                mo.fail_op = 1 + rng() % 2;
            } else if (kind == 2) {
                mo.fail_stream = static_cast<int>(victim);
                mo.fail_read = false;
                mo.fail_op = 1;
            }
            mo.fail_op_stat = code;
            if (kind == 3)
                mo.fail_hbm_poll = 1 + rng() % 2;
            auto model = make_file_shell_model(vol->device(), mo);
            JobOptions jo;
            jo.extend_bytes = (1 + rng() % 2) * CLUSTER - rng() % 1000;
            // Job 1 first leaves a job running on the same shell, so its submit() must wait out the drain.
            std::optional<Output> leftover;
            if (iter == 1) {
                leftover = vol->reserve("/leftover", CLUSTER);
                vol->flush();
                Job left(*model, *vol, jo);
                left.add_stream({biggest}, *leftover, digest_fill_args(CLUSTER, 1));
                left.submit();
                CHECK((model->read32(0x04) & 1) != 0);
            }
            Job job(*model, *vol, jo);
            for (auto& x : ss)
                job.add_stream(x.in, x.out, digest_fill_args(x.fill, x.seed));
            job.submit();
            const auto res = job.wait();
            if (leftover)
                vol->abandon(*leftover);
            vol->commit();
            CHECK(!vol->dirty());
            if (kind == 0) {
                if (!res.ok)
                    throw TestFailure("job failed: " + res.error);
                for (uint32_t s = 0; s < nstreams; ++s) {
                    std::vector<std::vector<uint8_t>> data;
                    uint64_t in_total = 0;
                    for (const auto& p : ss[s].in) {
                        data.push_back(inputs.at(p));
                        in_total += data.back().size();
                    }
                    const auto expect = digest_fill_expected(data, ss[s].fill, ss[s].seed);
                    CHECK_EQ(res.streams[s].out_bytes, static_cast<uint64_t>(expect.size()));
                    CHECK_EQ(res.streams[s].in_bytes, in_total);
                    CHECK_EQ(res.streams[s].in_files, static_cast<uint64_t>(ss[s].in.size()));
                    CHECK(read_file(*vol, ss[s].out.path) == expect);
                    outputs[ss[s].out.path] = expect;
                    total_ext += res.streams[s].extensions;
                }
            } else if (kind == 3) {
                CHECK(!res.ok);
                for (const auto& r : res.streams) {
                    CHECK(r.failed);
                    CHECK_EQ(r.err_info, 3u << 8);
                }
                for (const auto& x : ss)
                    CHECK(!vol->exists(x.out.path));
                std::printf("job %d: injected HBM failure: %s\n", job_no, res.error.c_str());
            } else {
                CHECK(!res.ok);
                const auto& r = res.streams[victim];
                const uint32_t mask = model->injected_stream_mask();
                CHECK(r.failed);
                CHECK(mask >> victim & 1);
                CHECK_EQ(r.err_info, model->injected_err_info());
                CHECK_EQ((r.err_info >> 8) & 0xF, 0u);
                CHECK_EQ((r.err_info >> 2) & 1, kind == 1 ? 1u : 0u);
                CHECK_EQ(r.err_info & 3, code);
                if (code == 2) {
                    CHECK_EQ((r.err_info >> 4) & 0xF, 0u);
                    CHECK_EQ(r.err_info >> 16, 0u);
                }
                if (kind == 1)
                    CHECK_EQ(mask, code == 3 ? (1u << nstreams) - 1 : 1u << victim);
                uint32_t fanout = 0;
                for (uint32_t s = 0; s < nstreams; ++s) {
                    CHECK_EQ(res.streams[s].failed ? 1u : 0u, mask >> s & 1);
                    if (res.streams[s].failed)
                        CHECK_EQ(res.streams[s].err_info, r.err_info);
                    fanout += res.streams[s].failed;
                }
                for (const auto& x : ss)
                    CHECK(!vol->exists(x.out.path));
                std::printf("job %d: injected %s failure code %u, %u of %u streams failed: %s\n", job_no, kind == 1 ? "read" : "write",
                            code, fanout, nstreams, res.error.c_str());
            }
            ++job_no;
        }
        CHECK(total_ext > 0);
        std::printf("jobs %d, NEED_SPACE extensions %u, multi-extent inputs %u\n", job_no, total_ext, multi_extent);
        vol->close();
        vol.reset();
        check_volume(image, tmp, "jobs");
        vol = open_volume(image, true);
        for (const auto& [p, d] : inputs)
            CHECK(read_file(*vol, p) == d);
        for (const auto& [p, d] : outputs)
            CHECK(read_file(*vol, p) == d);
        CHECK(vol->check().clean());
    });
}
