// digest_fill_run.cpp: DIGEST_FILL job argument parser and result report
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#include "iuv_exfat/digest_fill_run.hpp"

#include <chrono>
#include <cstring>
#include <format>
#include <optional>
#include <stdexcept>

#include "iuv_exfat/file_shell_model.hpp"
#include "iuv_exfat/util.hpp"

namespace iuv_exfat {

namespace {

constexpr uint64_t RECORD_BYTES = 32;

void abandon_all(Volume& vol, std::vector<Output>& outs)
{
    for (auto& o : outs)
        vol.abandon(o);
    vol.commit();
}

} // namespace

DigestFillRun parse_digest_fill_run(const std::vector<std::string>& args)
{
    DigestFillRun run;
    run.streams.emplace_back();
    for (size_t i = 0; i < args.size(); ++i) {
        const auto& a = args[i];
        auto next = [&]() -> std::string {
            if (i + 1 >= args.size())
                throw std::invalid_argument(a + " needs a value");
            return args[++i];
        };
        auto next_u64 = [&](uint64_t max = UINT64_MAX) { return parse_u64(next(), max); };
        if (a == "--fill-bytes")
            run.fill_bytes = next_u64();
        else if (a == "--seed")
            run.seed = static_cast<uint32_t>(next_u64(UINT32_MAX));
        else if (a == "--reserve")
            run.reserve = next_u64();
        else if (a == "--extend")
            run.extend_bytes = next_u64();
        else if (a == "--model-seed")
            run.model_seed = next_u64();
        else if (a == "--card")
            run.card = next();
        else if (a == "--compatible")
            run.compatible = next();
        else if (a == "--")
            run.streams.emplace_back();
        else
            run.streams.back().push_back(a);
    }
    for (const auto& s : run.streams)
        if (s.size() < 2)
            throw std::invalid_argument("each stream needs <out> and at least one <in>");
    if (run.reserve == 0)
        run.reserve = run.fill_bytes + RECORD_BYTES;
    return run;
}

std::vector<Output> reserve_digest_fill_outputs(Volume& vol, const DigestFillRun& run)
{
    std::vector<Output> outs;
    outs.reserve(run.streams.size());
    try {
        for (const auto& s : run.streams)
            outs.push_back(vol.reserve(s[0], run.reserve));
        vol.flush();
    } catch (...) {
        abandon_all(vol, outs);
        throw;
    }
    return outs;
}

JobResult run_digest_fill(Volume& vol, const DigestFillRun& run, std::vector<Output>& outs, MiBus* card,
                          BlockDevice* model_dev, std::mutex* volume_mutex)
{
    std::unique_ptr<MiBus> model;
    std::optional<Job> job;
    try {
        if (!card) {
            FileShellModelOptions mo;
            mo.seed = run.model_seed;
            model = make_file_shell_model(*model_dev, mo);
        }
        JobOptions jo;
        jo.extend_bytes = run.extend_bytes;
        jo.volume_mutex = volume_mutex;
        if (card)
            jo.poll_interval = std::chrono::microseconds(50);
        job.emplace(card ? *card : *model, vol, jo);
        for (size_t s = 0; s < run.streams.size(); ++s)
            job->add_stream(std::vector<std::string>(run.streams[s].begin() + 1, run.streams[s].end()), outs[s],
                            digest_fill_args(run.fill_bytes, run.seed));
        job->submit();
    } catch (...) {
        // START was never written, so the shell cannot write into the outputs and they can go at once.
        std::unique_lock<std::mutex> lock;
        if (volume_mutex)
            lock = std::unique_lock(*volume_mutex);
        abandon_all(vol, outs);
        throw;
    }
    return job->wait();
}

std::string digest_fill_report(Volume& vol, const DigestFillRun& run, const JobResult& res)
{
    std::string out;
    for (size_t s = 0; s < res.streams.size(); ++s) {
        const auto& r = res.streams[s];
        out += std::format("stream {}: in_files {} in_bytes {} out_bytes {} extensions {}{}{}\n", s, r.in_files,
                           r.in_bytes, r.out_bytes, r.extensions, r.failed ? " FAILED: " : "", r.err_text);
    }
    if (!res.ok)
        return out;
    for (size_t s = 0; s < run.streams.size(); ++s) {
        const auto& path = run.streams[s][0];
        const uint64_t size = vol.stat(path).size;
        if (size < RECORD_BYTES)
            throw std::runtime_error("output shorter than the record: " + path);
        const auto rec = read_file_range(vol, path, size - RECORD_BYTES, RECORD_BYTES);
        uint64_t f[3];
        uint32_t cnt, magic;
        std::memcpy(f, rec.data(), 24);
        std::memcpy(&cnt, rec.data() + 24, 4);
        std::memcpy(&magic, rec.data() + 28, 4);
        out += std::format("stream {} record: in_bytes {} sum 0x{:016x} xor 0x{:016x} files {} magic 0x{:08x}\n", s,
                           f[0], f[1], f[2], cnt, magic);
    }
    return out;
}

} // namespace iuv_exfat
