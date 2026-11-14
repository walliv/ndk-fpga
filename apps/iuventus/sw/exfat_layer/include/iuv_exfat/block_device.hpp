// block_device.hpp: raw block device access for the exFAT metadata layer
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <memory>
#include <span>
#include <string>
#include <string_view>

namespace iuv_exfat {

constexpr uint32_t LBA_BYTES = 512;
// O_DIRECT alignment of offsets, lengths and buffers.
constexpr uint64_t IO_ALIGN  = 4096;

constexpr uint64_t align_down(uint64_t v) { return v & ~(IO_ALIGN - 1); }
constexpr uint64_t align_up(uint64_t v) { return align_down(v + IO_ALIGN - 1); }

struct FreeDeleter {
    void operator()(uint8_t* p) const { std::free(p); }
};
using AlignedBuf = std::unique_ptr<uint8_t, FreeDeleter>;

// IO_ALIGN aligned and at least IO_ALIGN bytes, so even an empty request gets a buffer it can free.
AlignedBuf alloc_aligned(size_t bytes);
// Throws out_of_range unless [offset, offset + len) lies within a device of dev_bytes.
void check_range(uint64_t dev_bytes, uint64_t offset, uint64_t len, std::string_view dev_name);

class BlockDevice {
public:
    virtual ~BlockDevice() = default;

    virtual uint64_t size() const = 0;
    virtual void read(uint64_t offset, std::span<uint8_t> buf) = 0;
    virtual void write(uint64_t offset, std::span<const uint8_t> buf) = 0;
    virtual void flush() = 0;
    virtual void discard(uint64_t offset, uint64_t len) = 0;
};

// O_DIRECT with 4 KiB aligned bounce buffers; buffered I/O only where O_DIRECT is refused.
std::unique_ptr<BlockDevice> open_block_device(const std::string& path, bool read_only = false);

} // namespace iuv_exfat
