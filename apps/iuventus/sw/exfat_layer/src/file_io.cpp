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
    const auto fe = vol.extents(path);
    std::vector<uint8_t> out(fe.size, 0);
    uint64_t pos = 0;
    for (const auto& e : fe.extents) {
        if (pos >= fe.valid_size)
            break;
        const uint64_t len = std::min<uint64_t>(static_cast<uint64_t>(e.count) * LBA_BYTES, fe.valid_size - pos);
        vol.device().read(e.lba * LBA_BYTES, std::span(out.data() + pos, len));
        pos += len;
    }
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
