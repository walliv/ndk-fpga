// job.hpp: one file shell job driven over MI against an exFAT volume
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <chrono>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "iuv_exfat/mi_bus.hpp"
#include "iuv_exfat/volume.hpp"

namespace iuv_exfat {

constexpr uint32_t KERNEL_DIGEST_FILL = 1;
constexpr uint32_t MAX_STREAMS        = 8;

// Words of one stream's 512 B kernel argument window.
std::vector<uint32_t> digest_fill_args(uint64_t fill_bytes, uint32_t seed);

// ERR_INFO sources: 0 NVMe status, 1 FORMAT (1-based ring entry modulo 65536 in 31:16; 0 without bit 2 may also be START), 2 ABORT, 3 HBM.
std::string describe_err_info(uint32_t err_info);

struct JobOptions {
    uint32_t                  kernel_id     = KERNEL_DIGEST_FILL;
    uint64_t                  extend_bytes  = 64ull << 20;
    std::chrono::microseconds poll_interval {0};
    // Longest stretch without IN_BYTES or OUT_BYTES moving before the job is aborted.
    std::chrono::milliseconds timeout       {60000};
};

struct StreamResult {
    uint64_t in_files   = 0;
    uint64_t in_bytes   = 0;
    uint64_t out_bytes  = 0;
    uint32_t status     = 0;
    uint32_t err_info   = 0;
    std::string err_text;
    uint32_t extensions = 0;
    bool     failed     = false;
};

struct JobResult {
    bool                      ok = false;
    std::string               error;
    std::vector<StreamResult> streams;
};

class Job {
public:
    Job(MiBus& bus, Volume& volume, JobOptions opts = {});
    ~Job();
    Job(const Job&) = delete;
    Job& operator=(const Job&) = delete;

    // The output must stay alive and untouched by the caller until wait() returns.
    void add_stream(std::vector<std::string> inputs, Output& output, std::vector<uint32_t> kernel_args);
    void submit();
    // DONE stages finalize, ERR or timeout stages abandon; the caller commits.
    JobResult wait();

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace iuv_exfat
