// block_device.cpp: O_DIRECT block device and image file access
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#include "iuv_exfat/block_device.hpp"

#include <algorithm>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <string>
#include <system_error>

#include <fcntl.h>
#include <linux/falloc.h>
#include <linux/fs.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace iuv_exfat {

namespace {

constexpr size_t BUF_BYTES = 8u << 20;

[[noreturn]] void throw_errno(const std::string& what)
{
    throw std::system_error(errno, std::generic_category(), what);
}

class FileBlockDevice final : public BlockDevice {
public:
    FileBlockDevice(const std::string& path, bool read_only)
        : path_(path)
    {
        const int base = (read_only ? O_RDONLY : O_RDWR) | O_CLOEXEC;
        fd_ = ::open(path.c_str(), base | O_DIRECT);
        direct_ = fd_ >= 0;
        if (fd_ < 0 && errno == EINVAL)
            fd_ = ::open(path.c_str(), base);
        if (fd_ < 0)
            throw_errno("open " + path);

        struct stat st {};
        if (::fstat(fd_, &st) != 0)
            throw_errno("fstat " + path);
        is_blk_ = S_ISBLK(st.st_mode);
        if (is_blk_) {
            uint64_t bytes = 0;
            if (::ioctl(fd_, BLKGETSIZE64, &bytes) != 0)
                throw_errno("BLKGETSIZE64 " + path);
            size_ = bytes;
        } else {
            size_ = static_cast<uint64_t>(st.st_size);
        }
        if (direct_ && size_ % IO_ALIGN != 0)
            drop_direct();
        buf_ = alloc_aligned(BUF_BYTES);
    }

    ~FileBlockDevice() override
    {
        if (fd_ >= 0)
            ::close(fd_);
    }

    uint64_t size() const override { return size_; }

    void read(uint64_t offset, std::span<uint8_t> buf) override
    {
        check_range(offset, buf.size());
        if (!direct_) {
            pread_full(buf.data(), buf.size(), offset);
            return;
        }
        uint64_t pos = offset;
        const uint64_t end = offset + buf.size();
        while (pos < end) {
            const uint64_t win_lo = align_down(pos);
            const uint64_t win_hi = std::min(align_up(end), win_lo + BUF_BYTES);
            pread_full(buf_.get(), win_hi - win_lo, win_lo);
            const uint64_t copy_hi = std::min(end, win_hi);
            std::memcpy(buf.data() + (pos - offset), buf_.get() + (pos - win_lo), copy_hi - pos);
            pos = copy_hi;
        }
    }

    void write(uint64_t offset, std::span<const uint8_t> buf) override
    {
        check_range(offset, buf.size());
        if (!direct_) {
            pwrite_full(buf.data(), buf.size(), offset);
            return;
        }
        uint64_t pos = offset;
        const uint64_t end = offset + buf.size();
        while (pos < end) {
            const uint64_t win_lo = align_down(pos);
            const uint64_t win_hi = std::min(align_up(end), win_lo + BUF_BYTES);
            const uint64_t copy_hi = std::min(end, win_hi);
            const bool head_partial = win_lo < pos;
            const bool tail_partial = copy_hi < win_hi;
            if (head_partial)
                pread_full(buf_.get(), IO_ALIGN, win_lo);
            if (tail_partial && !(head_partial && win_hi - win_lo == IO_ALIGN))
                pread_full(buf_.get() + (win_hi - IO_ALIGN - win_lo), IO_ALIGN, win_hi - IO_ALIGN);
            std::memcpy(buf_.get() + (pos - win_lo), buf.data() + (pos - offset), copy_hi - pos);
            pwrite_full(buf_.get(), win_hi - win_lo, win_lo);
            pos = copy_hi;
        }
    }

    void flush() override
    {
        if (::fsync(fd_) != 0)
            throw_errno("fsync " + path_);
    }

    void discard(uint64_t offset, uint64_t len) override
    {
        check_range(offset, len);
        const uint64_t lo = align_up(offset);
        const uint64_t hi = align_down(offset + len);
        if (hi <= lo)
            return;
        int rc = 0;
        if (is_blk_) {
            uint64_t range[2] = {lo, hi - lo};
            rc = ::ioctl(fd_, BLKDISCARD, range);
        } else {
            rc = ::fallocate(fd_, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE, static_cast<off_t>(lo),
                             static_cast<off_t>(hi - lo));
        }
        if (rc != 0 && errno != EOPNOTSUPP && errno != ENOTTY)
            throw_errno("discard " + path_);
    }

private:
    static uint64_t align_down(uint64_t v) { return v & ~(IO_ALIGN - 1); }
    static uint64_t align_up(uint64_t v) { return align_down(v + IO_ALIGN - 1); }

    void check_range(uint64_t offset, uint64_t len) const { iuv_exfat::check_range(size_, offset, len, path_); }

    void drop_direct()
    {
        const int flags = ::fcntl(fd_, F_GETFL);
        if (flags < 0 || ::fcntl(fd_, F_SETFL, flags & ~O_DIRECT) != 0)
            throw_errno("fcntl " + path_);
        direct_ = false;
    }

    // EINTR repeats the call; EINVAL under O_DIRECT repeats it buffered.
    bool retry_after_error()
    {
        if (errno == EINTR)
            return true;
        if (errno == EINVAL && direct_) {
            drop_direct();
            return true;
        }
        return false;
    }

    void pread_full(uint8_t* dst, uint64_t len, uint64_t offset)
    {
        while (len > 0) {
            const ssize_t n = ::pread(fd_, dst, len, static_cast<off_t>(offset));
            if (n < 0) {
                if (retry_after_error())
                    continue;
                throw_errno("read " + path_);
            }
            if (n == 0) {
                std::memset(dst, 0, len);
                return;
            }
            dst += n;
            len -= static_cast<uint64_t>(n);
            offset += static_cast<uint64_t>(n);
        }
    }

    void pwrite_full(const uint8_t* src, uint64_t len, uint64_t offset)
    {
        while (len > 0) {
            const ssize_t n = ::pwrite(fd_, src, len, static_cast<off_t>(offset));
            if (n < 0) {
                if (retry_after_error())
                    continue;
                throw_errno("write " + path_);
            }
            src += n;
            len -= static_cast<uint64_t>(n);
            offset += static_cast<uint64_t>(n);
        }
    }

    std::string                          path_;
    int                                  fd_     = -1;
    bool                                 direct_ = false;
    bool                                 is_blk_ = false;
    uint64_t                             size_   = 0;
    std::unique_ptr<uint8_t, FreeDeleter> buf_;
};

} // namespace

std::unique_ptr<BlockDevice> open_block_device(const std::string& path, bool read_only)
{
    return std::make_unique<FileBlockDevice>(path, read_only);
}

AlignedBuf alloc_aligned(size_t bytes)
{
    void* mem = nullptr;
    if (::posix_memalign(&mem, IO_ALIGN, std::max<size_t>(bytes, IO_ALIGN)) != 0)
        throw std::bad_alloc();
    return AlignedBuf(static_cast<uint8_t*>(mem));
}

void check_range(uint64_t dev_bytes, uint64_t offset, uint64_t len, std::string_view dev_name)
{
    if (offset > dev_bytes || len > dev_bytes - offset)
        throw std::out_of_range("I/O beyond the end of " + std::string(dev_name));
}

} // namespace iuv_exfat
