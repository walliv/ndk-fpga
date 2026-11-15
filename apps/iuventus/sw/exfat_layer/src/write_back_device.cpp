// write_back_device.cpp: block device wrapper that holds written pages in memory until the next flush
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#include <algorithm>
#include <cstring>
#include <map>
#include <mutex>
#include <vector>

#include "iuv_exfat/block_device.hpp"

namespace iuv_exfat {

namespace {

constexpr uint64_t PAGE = 4096;

class WriteBackDevice final : public BlockDevice {
public:
    explicit WriteBackDevice(std::unique_ptr<BlockDevice> inner) : inner_(std::move(inner)) {}

    uint64_t size() const override { return inner_->size(); }

    void read(uint64_t offset, std::span<uint8_t> buf) override
    {
        std::lock_guard lock(mu_);
        check_range(inner_->size(), offset, buf.size(), "the device");
        const uint64_t end = offset + buf.size();
        uint64_t pos = offset;
        auto it = pages_.upper_bound(offset);
        if (it != pages_.begin())
            --it;
        while (pos < end) {
            while (it != pages_.end() && it->first + PAGE <= pos)
                ++it;
            const uint64_t next = it == pages_.end() ? end : std::min(end, std::max(pos, it->first));
            if (pos < next) {
                inner_->read(pos, buf.subspan(pos - offset, next - pos));
                pos = next;
                continue;
            }
            const uint64_t hi = std::min(end, it->first + PAGE);
            std::memcpy(buf.data() + (pos - offset), it->second.get() + (pos - it->first), hi - pos);
            pos = hi;
        }
    }

    void write(uint64_t offset, std::span<const uint8_t> buf) override
    {
        std::lock_guard lock(mu_);
        check_range(inner_->size(), offset, buf.size(), "the device");
        const uint64_t end = offset + buf.size();
        for (uint64_t page = offset - offset % PAGE; page < end; page += PAGE) {
            auto& mem = pages_[page];
            const uint64_t lo = std::max(offset, page);
            const uint64_t hi = std::min(end, page + PAGE);
            if (!mem) {
                mem = alloc_aligned(PAGE);
                const uint64_t valid = std::min(PAGE, inner_->size() - page);
                if (lo > page || hi < page + valid)
                    inner_->read(page, std::span(mem.get(), valid));
            }
            std::memcpy(mem.get() + (lo - page), buf.data() + (lo - offset), hi - lo);
        }
    }

    void flush() override
    {
        std::lock_guard lock(mu_);
        write_out();
        inner_->flush();
    }

    void discard(uint64_t offset, uint64_t len) override
    {
        std::lock_guard lock(mu_);
        write_out();
        inner_->discard(offset, len);
    }

private:
    // Adjacent pages go out as one aligned write; the cache keeps no clean pages, so later reads see the media.
    void write_out()
    {
        auto it = pages_.begin();
        while (it != pages_.end()) {
            auto run_end = std::next(it);
            while (run_end != pages_.end() && run_end->first == std::prev(run_end)->first + PAGE)
                ++run_end;
            const uint64_t first = it->first;
            const uint64_t bytes = std::min<uint64_t>(std::prev(run_end)->first + PAGE, inner_->size()) - first;
            AlignedBuf run = alloc_aligned(bytes + PAGE);
            for (auto p = it; p != run_end; ++p)
                std::memcpy(run.get() + (p->first - first), p->second.get(), std::min(PAGE, bytes - (p->first - first)));
            inner_->write(first, std::span<const uint8_t>(run.get(), bytes));
            it = run_end;
        }
        pages_.clear();
    }

    std::unique_ptr<BlockDevice>  inner_;
    std::mutex                    mu_;
    std::map<uint64_t, AlignedBuf> pages_;
};

} // namespace

std::unique_ptr<BlockDevice> make_write_back_device(std::unique_ptr<BlockDevice> inner)
{
    return std::make_unique<WriteBackDevice>(std::move(inner));
}

} // namespace iuv_exfat
