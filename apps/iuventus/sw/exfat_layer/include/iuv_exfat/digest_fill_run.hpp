// digest_fill_run.hpp: DIGEST_FILL job arguments and result report shared by the CLI and the FUSE daemon
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

#include "iuv_exfat/block_device.hpp"
#include "iuv_exfat/job.hpp"
#include "iuv_exfat/mi_bus.hpp"
#include "iuv_exfat/volume.hpp"

namespace iuv_exfat {

struct DigestFillRun {
    // Each stream: the output path, then its input paths.
    std::vector<std::vector<std::string>> streams;
    uint64_t    fill_bytes   = 1 << 20;
    uint32_t    seed         = 0x5EED;
    uint64_t    reserve      = 0;
    uint64_t    extend_bytes = 64ull << 20;
    uint64_t    model_seed   = 1;
    std::string card;
    std::string compatible   = FILE_SHELL_COMPATIBLE;
};

// <out> <in>... [-- <out> <in>...] with --fill-bytes, --seed, --reserve, --extend, --model-seed, --card, --compatible.
DigestFillRun parse_digest_fill_run(const std::vector<std::string>& args);
// Reserves and flushes every stream's output; a failure abandons those reserved and commits.
std::vector<Output> reserve_digest_fill_outputs(Volume& vol, const DigestFillRun& run);
// Runs the job on card, or on the software model over model_dev without one; the caller commits. A failure before START
// abandons the outputs and commits, while a failing wait() leaves them reserved for recover().
JobResult run_digest_fill(Volume& vol, const DigestFillRun& run, std::vector<Output>& outs, MiBus* card,
                          BlockDevice* model_dev, std::mutex* volume_mutex = nullptr);
// One line per stream, then each output's digest record when the job succeeded.
std::string digest_fill_report(Volume& vol, const DigestFillRun& run, const JobResult& res);

} // namespace iuv_exfat
