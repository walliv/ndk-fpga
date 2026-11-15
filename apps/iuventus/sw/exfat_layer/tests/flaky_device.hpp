// flaky_device.hpp: BlockDevice wrapper failing one chosen write or read with EIO
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <memory>
#include <system_error>

#include "iuv_exfat/block_device.hpp"

namespace iuv_test {

// Fails the k-th write after arm(k), or the next read after fail_next_read(), with EIO and works normally otherwise.
class FlakyDevice final : public iuv_exfat::BlockDevice {
public:
    explicit FlakyDevice(std::unique_ptr<iuv_exfat::BlockDevice> inner) : inner_(std::move(inner)) {}

    uint64_t size() const override { return inner_->size(); }
    void read(uint64_t offset, std::span<uint8_t> buf) override
    {
        if (fail_read_) {
            fail_read_ = false;
            throw std::system_error(std::make_error_code(std::errc::io_error), "injected read error");
        }
        inner_->read(offset, buf);
    }
    void write(uint64_t offset, std::span<const uint8_t> buf) override
    {
        if (armed_ && ++writes_ == fail_at_) {
            armed_ = false;
            throw std::system_error(std::make_error_code(std::errc::io_error), "injected write error");
        }
        inner_->write(offset, buf);
    }
    void flush() override { inner_->flush(); }
    void discard(uint64_t offset, uint64_t len) override { inner_->discard(offset, len); }

    // k = 0 counts the writes without failing one.
    void arm(uint64_t k)
    {
        armed_   = true;
        fail_at_ = k;
        writes_  = 0;
    }
    uint64_t writes() const { return writes_; }
    void     fail_next_read() { fail_read_ = true; }

private:
    std::unique_ptr<iuv_exfat::BlockDevice> inner_;
    bool                                    armed_     = false;
    bool                                    fail_read_ = false;
    uint64_t                                fail_at_   = 0;
    uint64_t                                writes_    = 0;
};

} // namespace iuv_test
