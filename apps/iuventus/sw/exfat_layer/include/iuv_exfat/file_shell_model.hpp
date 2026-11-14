// file_shell_model.hpp: software model of the Iuventus file shell with the DIGEST_FILL kernel
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <cstdint>
#include <memory>

#include "iuv_exfat/block_device.hpp"
#include "iuv_exfat/mi_bus.hpp"

namespace iuv_exfat {

// Stripe geometry comes from the STRIPE register, as in the RTL.
struct FileShellModelOptions {
    uint64_t seed            = 1;
    uint32_t log2_in_ring    = 16;
    uint32_t log2_out_ring   = 14;
    // Input entries the shell may hold in flight beyond IN_HEAD.
    uint32_t in_window       = 32;
    uint32_t max_ops_per_poll = 8;
    // Fault injection: fail the fail_op-th (1-based) read or write I/O of fail_stream.
    int      fail_stream     = -1;
    bool     fail_read       = true;
    uint64_t fail_op         = 0;
    uint32_t fail_op_stat    = 2;
    // Non-OKAY HBM response on the ring port at this STATUS poll, 0 for never.
    uint64_t fail_hbm_poll   = 0;
};

class FileShellModel : public MiBus {
public:
    // ERR_INFO of the injected failure, 0 before it fired.
    virtual uint32_t injected_err_info() const = 0;
    // Streams the injected failure set ERR on.
    virtual uint32_t injected_stream_mask() const = 0;
    virtual uint64_t polls() const = 0;
};

std::unique_ptr<FileShellModel> make_file_shell_model(BlockDevice& dev, FileShellModelOptions opts = {});

} // namespace iuv_exfat
