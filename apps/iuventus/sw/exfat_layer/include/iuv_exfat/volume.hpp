// volume.hpp: exFAT volume metadata owner for the DMA Iuventus file layer
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <algorithm>
#include <cstdint>
#include <memory>
#include <string>
#include <system_error>
#include <vector>

#include "iuv_exfat/block_device.hpp"

namespace iuv_exfat {

// Logical LBAs of the whole device (partition start included), 512 B units.
struct Extent {
    uint64_t lba;
    uint32_t count;
};

struct VolumeOptions {
    uint32_t drives      = 4;
    uint32_t chunk_bytes = 128 * 1024;
    bool     read_only   = false;
    // The caller asserts a dirty volume is its own uncrashed session continued in this process, so no recover() is needed.
    bool     continue_session = false;
};

struct FileExtents {
    uint64_t            size       = 0;
    uint64_t            valid_size = 0;
    std::vector<Extent> extents;
};

struct DirEntryInfo {
    std::string name;
    bool        is_dir     = false;
    bool        unfinished = false;
    uint16_t    attributes = 0;
    uint64_t    size       = 0;
    uint64_t    valid_size = 0;
    // Unix seconds; 0 for the root directory, which has no entry set.
    int64_t     mtime      = 0;
};

// Handle of a reserved output file; extents cover whole reserved clusters.
struct Output {
    uint64_t            handle         = 0;
    std::string         path;
    uint64_t            reserved_bytes = 0;
    std::vector<Extent> extents;
};

struct VolumeInfo {
    uint64_t partition_offset_bytes = 0;
    uint64_t heap_offset_bytes      = 0;
    uint32_t cluster_bytes          = 0;
    uint32_t cluster_count          = 0;
    uint32_t free_clusters          = 0;
    uint32_t fat_chain_files        = 0;
    uint32_t directories            = 0;
    uint32_t files                  = 0;
    bool     dirty                  = false;
};

struct CheckReport {
    uint64_t owned_clusters   = 0;
    uint64_t leaked_clusters  = 0;
    uint64_t missing_clusters = 0;
    uint64_t cross_linked     = 0;
    bool clean() const { return leaked_clusters == 0 && missing_clusters == 0 && cross_linked == 0; }
};

struct RecoverReport {
    uint32_t deleted_unfinished = 0;
    uint32_t entries_past_eod   = 0;
    uint32_t truncated_chains   = 0;
    uint64_t bits_cleared       = 0;
    uint64_t bits_set           = 0;
};

class Volume {
public:
    virtual ~Volume() = default;

    static std::unique_ptr<Volume> open(std::unique_ptr<BlockDevice> dev, VolumeOptions opts = {});

    virtual BlockDevice& device() = 0;
    virtual VolumeOptions options() const = 0;
    virtual VolumeInfo info() const = 0;
    virtual bool dirty() const = 0;
    virtual bool reservations_flushed() const = 0;

    virtual std::vector<DirEntryInfo> list(const std::string& path) = 0;
    virtual DirEntryInfo stat(const std::string& path) = 0;
    virtual bool exists(const std::string& path) = 0;
    virtual FileExtents extents(const std::string& path) = 0;

    virtual void make_directory(const std::string& path) = 0;
    // Staged like abandon: the entry set and the clusters are released by the next commit().
    virtual void remove(const std::string& path) = 0;

    virtual Output reserve(const std::string& path, uint64_t nbytes) = 0;
    // Returns the extents appended to output.extents.
    virtual std::vector<Extent> extend(Output& output, uint64_t nbytes) = 0;
    virtual void finalize(Output& output, uint64_t nbytes) = 0;
    virtual void abandon(Output& output) = 0;
    // Takes over the unfinished entry at path as a live output; continues the session on a dirty volume.
    virtual Output adopt(const std::string& path) = 0;
    virtual void commit() = 0;
    virtual void flush() = 0;
    virtual RecoverReport recover() = 0;
    virtual CheckReport check() = 0;
    virtual void close() = 0;
};

// Calls fn(device_offset, offset_in_range, bytes) for each extent piece of the file range [off, off + len); EFBIG past the extents.
template <class Fn>
void for_each_dev_range(const std::vector<Extent>& extents, uint64_t off, uint64_t len, Fn&& fn)
{
    if (len == 0)
        return;
    uint64_t ext_lo = 0;
    const uint64_t end = off + len;
    for (const auto& e : extents) {
        const uint64_t ext_hi = ext_lo + static_cast<uint64_t>(e.count) * LBA_BYTES;
        const uint64_t a = std::max(off, ext_lo);
        const uint64_t b = std::min(end, ext_hi);
        if (a < b)
            fn(e.lba * LBA_BYTES + (a - ext_lo), a - off, b - a);
        ext_lo = ext_hi;
        if (ext_lo >= end)
            return;
    }
    throw std::system_error(std::make_error_code(std::errc::file_too_large), "range beyond the file's clusters");
}

// Writes data at a 512 B aligned file offset into the extents, zero padding the last LBA.
void write_extents(BlockDevice& dev, const std::vector<Extent>& extents, uint64_t file_offset, std::span<const uint8_t> data);
// Bytes past ValidDataLength read as zero.
std::vector<uint8_t> read_file(Volume& vol, const std::string& path);
// len bytes from offset, clipped at DataLength.
std::vector<uint8_t> read_file_range(Volume& vol, const std::string& path, uint64_t offset, uint64_t len);
// reserve, write, finalize, commit.
void put_file(Volume& vol, const std::string& path, std::span<const uint8_t> data);

} // namespace iuv_exfat
