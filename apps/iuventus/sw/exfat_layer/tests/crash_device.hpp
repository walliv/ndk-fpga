// crash_device.hpp: BlockDevice wrapper modelling a volatile write cache that loses writes at a crash
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <algorithm>
#include <memory>
#include <random>
#include <stdexcept>
#include <vector>

#include "iuv_exfat/block_device.hpp"

namespace iuv_test {

struct CrashError : std::runtime_error {
    CrashError() : std::runtime_error("simulated crash") {}
};

// Writes are held until flush; at operation crash_at a random subset of the held writes reaches the media.
class CrashDevice final : public iuv_exfat::BlockDevice {
public:
    CrashDevice(std::unique_ptr<iuv_exfat::BlockDevice> inner, uint64_t seed, uint64_t crash_at)
        : inner_(std::move(inner)), rng_(seed), crash_at_(crash_at)
    {
    }

    uint64_t size() const override { return inner_->size(); }

    void read(uint64_t offset, std::span<uint8_t> buf) override
    {
        if (crashed_)
            throw CrashError();
        inner_->read(offset, buf);
        for (const auto& w : pending_) {
            const uint64_t lo = std::max(offset, w.offset);
            const uint64_t hi = std::min(offset + buf.size(), w.offset + w.data.size());
            if (lo < hi)
                std::copy_n(w.data.begin() + static_cast<ptrdiff_t>(lo - w.offset), hi - lo, buf.begin() + static_cast<ptrdiff_t>(lo - offset));
        }
    }

    void write(uint64_t offset, std::span<const uint8_t> buf) override
    {
        tick();
        pending_.push_back({offset, std::vector<uint8_t>(buf.begin(), buf.end())});
    }

    void flush() override
    {
        tick();
        for (const auto& w : pending_)
            inner_->write(w.offset, w.data);
        pending_.clear();
        inner_->flush();
    }

    // Discard is advisory: dropping it is a legal device behaviour and keeps read-your-writes simple.
    void discard(uint64_t, uint64_t) override { tick(); }

    uint64_t ops() const { return ops_; }
    uint64_t dropped() const { return dropped_; }
    uint64_t kept() const { return kept_; }

private:
    struct Pending {
        uint64_t             offset;
        std::vector<uint8_t> data;
    };

    void tick()
    {
        if (crashed_)
            throw CrashError();
        if (++ops_ == crash_at_) {
            for (const auto& w : pending_) {
                if (rng_() & 1) {
                    inner_->write(w.offset, w.data);
                    ++kept_;
                } else {
                    ++dropped_;
                }
            }
            pending_.clear();
            inner_->flush();
            crashed_ = true;
            throw CrashError();
        }
    }

    std::unique_ptr<iuv_exfat::BlockDevice> inner_;
    std::mt19937_64                          rng_;
    uint64_t                                 crash_at_;
    uint64_t                                 ops_     = 0;
    uint64_t                                 dropped_ = 0;
    uint64_t                                 kept_    = 0;
    bool                                     crashed_ = false;
    std::vector<Pending>                     pending_;
};

} // namespace iuv_test
