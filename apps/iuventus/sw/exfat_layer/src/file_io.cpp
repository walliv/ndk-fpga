// file_io.cpp: host-side file data transfer through the extents of an exFAT file
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#include <algorithm>
#include <stdexcept>

#include "iuv_exfat/volume.hpp"

namespace iuv_exfat {

void write_extents(BlockDevice& dev, const std::vector<Extent>& extents, uint64_t file_offset, std::span<const uint8_t> data)
{
    if (file_offset % LBA_BYTES != 0)
        throw std::invalid_argument("write_extents: unaligned file offset");
    for_each_dev_range(extents, file_offset, data.size(), [&](uint64_t dev_off, uint64_t at, uint64_t len) {
        const uint64_t whole = len - len % LBA_BYTES;
        if (whole > 0)
            dev.write(dev_off, data.subspan(at, whole));
        if (whole < len) {
            std::vector<uint8_t> tail(LBA_BYTES, 0);
            std::copy_n(data.begin() + static_cast<ptrdiff_t>(at + whole), len - whole, tail.begin());
            dev.write(dev_off + whole, tail);
        }
    });
}

std::vector<uint8_t> read_file(Volume& vol, const std::string& path)
{
    return read_file_range(vol, path, 0, UINT64_MAX);
}

std::vector<uint8_t> read_file_range(Volume& vol, const std::string& path, uint64_t offset, uint64_t len)
{
    const auto fe = vol.extents(path);
    const uint64_t lo = std::min(offset, fe.size);
    const uint64_t hi = lo + std::min(len, fe.size - lo);
    const uint64_t valid_hi = std::min(hi, fe.valid_size);
    std::vector<uint8_t> out(hi - lo, 0);
    if (lo < valid_hi)
        for_each_dev_range(fe.extents, lo, valid_hi - lo, [&](uint64_t dev_off, uint64_t at, uint64_t n) {
            vol.device().read(dev_off, std::span(out.data() + at, n));
        });
    return out;
}

void put_file(Volume& vol, const std::string& path, std::span<const uint8_t> data)
{
    Output out = vol.reserve(path, data.size());
    write_extents(vol.device(), out.extents, 0, data);
    vol.finalize(out, data.size());
    vol.commit();
}

} // namespace iuv_exfat
