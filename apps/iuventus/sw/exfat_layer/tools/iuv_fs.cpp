// iuv_fs.cpp: iuv-fs, a FUSE daemon that mounts an Iuventus exFAT volume and runs file shell jobs from a control file
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#define FUSE_USE_VERSION 312

#include <fuse.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <deque>
#include <functional>
#include <future>
#include <memory>
#include <mutex>
#include <new>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <system_error>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <fcntl.h>
#include <malloc.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <syslog.h>
#include <unistd.h>

#include "iuv_exfat/digest_fill_run.hpp"
#include "iuv_exfat/job.hpp"
#include "iuv_exfat/util.hpp"
#include "iuv_exfat/volume.hpp"

using namespace iuv_exfat;

namespace {

constexpr size_t      STAGE_BYTES   = 4u << 20;
constexpr uint64_t    MAX_GROWTH    = 1ull << 30;
constexpr uint32_t    IO_SIZE_HINT  = 1u << 20;
constexpr uint64_t    RA_CHUNK      = 4u << 20;
constexpr uint64_t    RA_DEPTH      = 3;
// Closes and removals within this window share one commit and its device flushes.
constexpr auto        COMMIT_DELAY  = std::chrono::milliseconds(100);
// close() reaches the daemon as an asynchronous release, so an unlink can overtake the close that preceded it.
constexpr auto        RELEASE_GRACE = std::chrono::milliseconds(200);
constexpr const char* CONTROL_PATH  = "/.iuv-job";
constexpr const char* ORPHAN_PREFIX = "/.iuv-fs-unlinked-";

// True when key names dir or lies below it.
bool at_or_below(const std::string& key, const std::string& dir)
{
    return key.compare(0, dir.size(), dir) == 0 && (key.size() == dir.size() || key[dir.size()] == '/');
}

// Mounting deletes every root entry with this prefix, so no other file may take such a name.
bool orphan_name(const std::string& path)
{
    return path.rfind(ORPHAN_PREFIX, 0) == 0 && path.find('/', 1) == std::string::npos;
}

// Finished files list only the LBAs their size needs; the rest of that block lies in the same cluster.
FileExtents block_extents(FileExtents fe)
{
    if (!fe.extents.empty()) {
        auto& last = fe.extents.back();
        last.count = static_cast<uint32_t>(align_up(static_cast<uint64_t>(last.count) * LBA_BYTES) / LBA_BYTES);
    }
    return fe;
}

// Runs the background reads and writes on a fixed set of threads; the stripe loses throughput with more large requests
// in flight than that.
class IoPool {
public:
    explicit IoPool(unsigned threads)
    {
        for (unsigned i = 0; i < threads; ++i)
            workers_.emplace_back([this] { run(); });
    }

    ~IoPool()
    {
        {
            std::lock_guard lock(mu_);
            stop_ = true;
        }
        cv_.notify_all();
        for (auto& w : workers_)
            w.join();
    }

    // Unlike a packaged_task, the future does not own fn, so fn may hold what holds the future.
    std::shared_future<void> submit(std::function<void()> fn)
    {
        Task task {std::move(fn), {}};
        auto done = task.done.get_future().share();
        {
            std::lock_guard lock(mu_);
            tasks_.push_back(std::move(task));
        }
        cv_.notify_one();
        return done;
    }

private:
    struct Task {
        std::function<void()> fn;
        std::promise<void>    done;
    };

    void run()
    {
        for (;;) {
            Task task;
            {
                std::unique_lock lock(mu_);
                cv_.wait(lock, [&] { return stop_ || !tasks_.empty(); });
                if (tasks_.empty())
                    return;
                task = std::move(tasks_.front());
                tasks_.pop_front();
            }
            try {
                task.fn();
                task.fn = nullptr;
                task.done.set_value();
            } catch (...) {
                task.fn = nullptr;
                task.done.set_exception(std::current_exception());
            }
        }
    }

    std::mutex                             mu_;
    std::condition_variable                cv_;
    std::deque<Task>                       tasks_;
    std::vector<std::thread>               workers_;
    bool                                   stop_ = false;
};

// A file opened for writing through the mount: a volume output until its last handle closes.
struct WriteState {
    std::mutex            mu;
    std::string           path;
    Output                out;
    std::atomic<uint64_t> size {0};
    AlignedBuf            stage {alloc_aligned(STAGE_BYTES)};
    // The stage holds the newest copy of file bytes [stage_off, stage_off + stage_len); stage_off is block aligned.
    uint64_t              stage_off = 0;
    uint64_t              stage_len = 0;
    // A full stage goes to the device from spare while the next one fills.
    AlignedBuf               spare {alloc_aligned(STAGE_BYTES)};
    std::shared_future<void> inflight;
    int                      opens     = 0;
    bool                     reopened  = false;

    ~WriteState()
    {
        if (inflight.valid())
            inflight.wait();
    }
};

// Sequential reads are served from chunks read ahead in the background, so device latency overlaps the FUSE round trips.
struct ReadAhead {
    struct Chunk {
        uint64_t                 off = 0;
        uint64_t                 len = 0;
        AlignedBuf               buf;
        std::shared_future<void> ready;
    };
    std::mutex                         mu;
    std::deque<std::shared_ptr<Chunk>> chunks;
    uint64_t                           expect = 0;
};

struct Handle {
    enum class Kind { READ, WRITE, CONTROL };
    Kind                        kind;
    std::string                 path;
    std::string                 key;
    FileExtents                 fe;
    std::shared_ptr<WriteState> ws;
    std::string                 ctl_in;
    std::string                 ctl_out;
    std::unique_ptr<ReadAhead>  ra;
    // The writer that opened a read handle's file later; until it finalizes, its stage and size are the newest bytes.
    std::shared_ptr<WriteState> live;
};

struct Options {
    std::string device;
    std::string mountpoint;
    std::string card;
    std::string compatible = FILE_SHELL_COMPATIBLE;
    uint32_t    drives     = 4;
    uint32_t    chunk_kib  = 128;
    uint32_t    threads    = 16;
    uint32_t    io_threads = 4;
    bool        direct_io  = false;
    bool        discard    = false;
    bool        recover    = false;
    bool        foreground = false;
    bool        debug      = false;
    std::vector<std::string> fuse_opts;
};

class Fs {
public:
    explicit Fs(const Options& o) : opts_(o)
    {
        VolumeOptions vo;
        vo.drives      = o.drives;
        vo.chunk_bytes = o.chunk_kib * 1024;
        vo.discard     = o.discard;
        vol_ = Volume::open(make_write_back_device(open_block_device(o.device)), vo);
        if (vol_->dirty()) {
            if (!o.recover)
                throw std::runtime_error("volume is dirty: mount with --recover");
            const auto r = vol_->recover();
            std::fprintf(stderr,
                         "iuv-fs: recovered: deleted unfinished %u, trimmed files %u, truncated chains %u, superseded sets %u\n",
                         r.deleted_unfinished, r.trimmed_files, r.truncated_chains, r.superseded_sets);
        }
        // Files unlinked while open when the daemon stopped without unmounting.
        bool orphans = false;
        for (const auto& d : vol_->list("/"))
            if (("/" + d.name).rfind(ORPHAN_PREFIX, 0) == 0) {
                vol_->remove("/" + d.name);
                orphans = true;
            }
        if (orphans)
            vol_->commit();
        data_ = open_block_device(o.device);
        if (!o.card.empty())
            card_ = open_nfb_mi_bus(o.card, o.compatible);
        else
            model_dev_ = open_block_device(o.device);
        const auto vi = vol_->info();
        cluster_    = vi.cluster_bytes;
        clusters_   = vi.cluster_count;
        mount_time_ = std::time(nullptr);
    }

    // ------------------------------------------------------------ metadata

    int getattr(const char* name, struct stat* st, fuse_file_info* fi)
    {
        if (fi) {
            // An unlinked open file has no path; its handle knows the hidden name it lives under.
            const auto* h = reinterpret_cast<const Handle*>(fi->fh);
            std::lock_guard lock(mu_);
            if (h->kind == Handle::Kind::CONTROL) {
                fill_control(st);
                return 0;
            }
            const std::string& p = h->ws ? h->ws->path : h->path;
            fill_stat(st, p, vol_->stat(p));
            return 0;
        }
        const std::string path = name;
        if (path == CONTROL_PATH) {
            std::lock_guard lock(mu_);
            fill_control(st);
            return 0;
        }
        std::lock_guard lock(mu_);
        if (hidden(key_of(path)))
            return -ENOENT;
        fill_stat(st, path, vol_->stat(path));
        return 0;
    }

    int readdir(const std::string& path, void* buf, fuse_fill_dir_t filler, fuse_readdir_flags flags)
    {
        std::lock_guard lock(mu_);
        if (!vol_->stat(path).is_dir)
            return -ENOTDIR;
        const auto plus = (flags & FUSE_READDIR_PLUS) ? FUSE_FILL_DIR_PLUS : static_cast<fuse_fill_dir_flags>(0);
        filler(buf, ".", nullptr, 0, static_cast<fuse_fill_dir_flags>(0));
        filler(buf, "..", nullptr, 0, static_cast<fuse_fill_dir_flags>(0));
        const std::string prefix = path == "/" ? "/" : path + "/";
        for (const auto& d : vol_->list(path)) {
            if (hidden(key_of(prefix + d.name)))
                continue;
            struct stat st {};
            fill_stat(&st, prefix + d.name, d);
            if (filler(buf, d.name.c_str(), &st, 0, plus))
                return 0;
        }
        if (path == "/") {
            struct stat st {};
            fill_control(&st);
            filler(buf, CONTROL_PATH + 1, &st, 0, plus);
        }
        return 0;
    }

    int mkdir(const std::string& path)
    {
        if (orphan_name(path))
            return -EPERM;
        std::lock_guard lock(mu_);
        settle(key_of(path));
        vol_->make_directory(path);
        return 0;
    }

    int remove(const std::string& path)
    {
        std::unique_lock lock(mu_);
        const auto key = key_of(path);
        if (hidden(key))
            return -ENOENT;
        if (job_busy_.count(key))
            return -EBUSY;
        release_cv_.wait_for(lock, RELEASE_GRACE, [&] { return !has_handles(key); });
        if (hidden(key))
            return -ENOENT;
        if (has_handles(key)) {
            make_orphan(path);
            return 0;
        }
        settle(key);
        vol_->remove(path);
        removed_.insert(key);
        stage();
        return 0;
    }

    int rename(const std::string& from, const std::string& to, unsigned int flags)
    {
        if (flags & RENAME_EXCHANGE)
            return -EINVAL;
        if (from == CONTROL_PATH || to == CONTROL_PATH || orphan_name(to))
            return -EPERM;
        std::unique_lock lock(mu_);
        const auto fk = key_of(from);
        const auto tk = key_of(to);
        for (const auto& [k, n] : job_busy_)
            if (at_or_below(k, fk) || at_or_below(k, tk))
                return -EBUSY;
        const bool replaces = fk != tk && !hidden(tk) && vol_->exists(to);
        if (replaces && (flags & RENAME_NOREPLACE))
            return -EEXIST;
        if (replaces)
            release_cv_.wait_for(lock, RELEASE_GRACE, [&] { return !has_handles(tk); });
        if (hidden(fk))
            return -ENOENT;
        std::string hide;
        if (replaces && has_handles(tk))
            hide = make_orphan(to);
        settle(tk);
        try {
            vol_->rename(from, to);
        } catch (...) {
            // The open target moved aside first, so a rename that fails after that (ENOSPC for the new set) moves it back.
            if (!hide.empty()) {
                vol_->rename(hide, to);
                rekey(hide, to);
                orphans_.erase(tk);
            }
            throw;
        }
        rekey(from, to);
        stage();
        return 0;
    }

    int statfs(struct statvfs* sv)
    {
        std::lock_guard lock(mu_);
        const uint32_t free = vol_->free_clusters();
        sv->f_bsize   = cluster_;
        sv->f_frsize  = cluster_;
        sv->f_blocks  = clusters_;
        sv->f_bfree   = free;
        sv->f_bavail  = free;
        sv->f_namemax = 255;
        return 0;
    }

    // ------------------------------------------------------------ open and close

    int open(const std::string& path, fuse_file_info* fi)
    {
        if (path == CONTROL_PATH) {
            auto* h = new Handle {Handle::Kind::CONTROL, path, key_of(path), {}, {}, {}, {}, {}, {}};
            fi->fh        = reinterpret_cast<uint64_t>(h);
            fi->direct_io = 1;
            return 0;
        }
        const int  acc   = fi->flags & O_ACCMODE;
        const bool trunc = (fi->flags & O_TRUNC) && acc != O_RDONLY;
        const auto key   = key_of(path);
        std::shared_ptr<WriteState> shared;
        auto h = std::make_unique<Handle>();
        h->path = path;
        h->key  = key;
        {
            std::lock_guard lock(mu_);
            if (hidden(key))
                return -ENOENT;
            if (job_busy_.count(key) && acc != O_RDONLY)
                return -EBUSY;
            if (acc != O_RDONLY)
                settle(key);
            if (auto it = writers_.find(key); it != writers_.end()) {
                shared = it->second;
                ++shared->opens;
                h->kind = Handle::Kind::WRITE;
                h->ws   = shared;
            } else {
                const auto d = vol_->stat(path);
                if (d.is_dir)
                    return -EISDIR;
                if (acc != O_RDONLY) {
                    shared  = reopen_writer(path, d.size);
                    h->kind = Handle::Kind::WRITE;
                    h->ws   = shared;
                } else {
                    h->kind = Handle::Kind::READ;
                    h->fe   = block_extents(vol_->extents(path));
                    h->ra   = std::make_unique<ReadAhead>();
                    if (auto c = closed_.find(key); c != closed_.end())
                        h->fe.size = h->fe.valid_size = c->second;
                    else if (d.unfinished)
                        h->fe.size = h->fe.valid_size = 0;
                    ++opens_[key];
                    readers_.insert(h.get());
                }
            }
        }
        if (shared && trunc) {
            std::lock_guard wl(shared->mu);
            truncate_writer(*shared, 0);
        }
        set_cache_flags(fi, h->kind);
        fi->fh = reinterpret_cast<uint64_t>(h.release());
        return 0;
    }

    int create(const std::string& path, fuse_file_info* fi)
    {
        if (path == CONTROL_PATH)
            return open(path, fi);
        if (orphan_name(path))
            return -EPERM;
        {
            std::lock_guard lock(mu_);
            settle(key_of(path));
            if (!vol_->exists(path)) {
                auto* h = new Handle {Handle::Kind::WRITE, path, key_of(path), {}, new_writer(path), {}, {}, {}, {}};
                set_cache_flags(fi, h->kind);
                fi->fh = reinterpret_cast<uint64_t>(h);
                return 0;
            }
            if (fi->flags & O_EXCL)
                return -EEXIST;
        }
        return open(path, fi);
    }

    int release(fuse_file_info* fi)
    {
        std::unique_ptr<Handle> h(reinterpret_cast<Handle*>(fi->fh));
        if (h->kind == Handle::Kind::CONTROL)
            return 0;
        if (h->kind == Handle::Kind::READ) {
            std::lock_guard lock(mu_);
            readers_.erase(h.get());
            if (--opens_[h->key] == 0) {
                opens_.erase(h->key);
                remove_orphan(h->key);
            }
            release_cv_.notify_all();
            return 0;
        }
        std::lock_guard wl(h->ws->mu);
        try {
            close_writer(*h->ws);
        } catch (const std::exception& e) {
            log_failure("finalize at close failed", e);
            throw;
        }
        return 0;
    }

    int fsync(fuse_file_info* fi)
    {
        if (failed_)
            return -EIO;
        auto* h = reinterpret_cast<Handle*>(fi->fh);
        if (h->kind != Handle::Kind::WRITE) {
            std::unique_lock lock(mu_);
            // A close just before reaches the daemon as a later release; the file is durable only once that finalized it.
            release_cv_.wait_for(lock, RELEASE_GRACE, [&] { return !writers_.count(h->key); });
            data_->flush();
            commit_staged();
            return 0;
        }
        auto& ws = *h->ws;
        std::lock_guard wl(ws.mu);
        flush_stage(ws);
        // The size is durable only in a finalized entry, so the file is committed at its current size and reopened.
        std::lock_guard lock(mu_);
        vol_->finalize(ws.out, ws.size);
        staged_ = true;
        commit_staged();
        ws.out      = vol_->reopen(ws.path);
        ws.reopened = true;
        return 0;
    }

    int fsyncdir()
    {
        std::lock_guard lock(mu_);
        commit_staged();
        return 0;
    }

    int truncate(const char* name, off_t size, fuse_file_info* fi)
    {
        std::shared_ptr<WriteState> ws;
        bool own = false;
        if (fi) {
            const auto* h = reinterpret_cast<const Handle*>(fi->fh);
            if (!h->ws)
                return -EBADF;
            ws = h->ws;
        } else {
            const std::string path = name;
            std::lock_guard lock(mu_);
            const auto key = key_of(path);
            if (hidden(key))
                return -ENOENT;
            settle(key);
            // Holding an open keeps a writer whose last release races this call from finalizing before the truncate.
            if (auto it = writers_.find(key); it != writers_.end()) {
                ws = it->second;
                ++ws->opens;
            } else {
                const auto d = vol_->stat(path);
                if (d.is_dir)
                    return -EISDIR;
                if (static_cast<uint64_t>(size) == d.size)
                    return 0;
                if (job_busy_.count(key))
                    return -EBUSY;
                ws = reopen_writer(path, d.size);
            }
            own = true;
        }
        std::lock_guard wl(ws->mu);
        truncate_writer(*ws, static_cast<uint64_t>(size));
        if (own)
            close_writer(*ws);
        return 0;
    }

    int fallocate(int mode, off_t off, off_t len, fuse_file_info* fi)
    {
        auto* h = reinterpret_cast<Handle*>(fi->fh);
        if (mode != FALLOC_FL_KEEP_SIZE || h->kind != Handle::Kind::WRITE)
            return -EOPNOTSUPP;
        std::lock_guard wl(h->ws->mu);
        ensure_reserved(*h->ws, static_cast<uint64_t>(off + len));
        return 0;
    }

    // ------------------------------------------------------------ data

    int read_buf(fuse_bufvec** bufp, size_t len, off_t offset, fuse_file_info* fi)
    {
        auto* h = reinterpret_cast<Handle*>(fi->fh);
        const auto off = static_cast<uint64_t>(offset);
        if (h->kind == Handle::Kind::CONTROL) {
            const std::string& text = h->ctl_out.empty() ? last_report() : h->ctl_out;
            const uint64_t lo = std::min<uint64_t>(off, text.size());
            const uint64_t n  = std::min<uint64_t>(len, text.size() - lo);
            auto* mem = static_cast<uint8_t*>(std::malloc(std::max<uint64_t>(n, 1)));
            std::memcpy(mem, text.data() + lo, n);
            return reply_mem(bufp, mem, n);
        }
        if (h->kind == Handle::Kind::WRITE)
            return read_writer(*h->ws, bufp, len, off);
        FileExtents fe;
        std::shared_ptr<WriteState> live;
        {
            std::lock_guard rl(h->ra->mu);
            fe   = h->fe;
            live = h->live;
        }
        if (live)
            return read_writer(*live, bufp, len, off);
        const uint64_t end = std::min<uint64_t>(off + len, fe.size);
        if (off >= end)
            return reply_mem(bufp, alloc_aligned(0).release(), 0);
        const auto use = read_ahead(*h, off, end);
        if (use.empty())
            return reply_mem(bufp, read_aligned(fe.extents, fe.valid_size, off, end), end - off);
        AlignedBuf mem(alloc_aligned(end - off));
        for (const auto& c : use) {
            c->ready.get();
            const uint64_t a = std::max(off, c->off);
            const uint64_t b = std::min(end, c->off + c->len);
            std::memcpy(mem.get() + (a - off), c->buf.get() + (a - c->off), b - a);
        }
        return reply_mem(bufp, mem.release(), end - off);
    }

    int read_writer(WriteState& ws, fuse_bufvec** bufp, size_t len, uint64_t off)
    {
        std::lock_guard wl(ws.mu);
        drain(ws);
        const uint64_t size = ws.size;
        const uint64_t end  = std::min<uint64_t>(off + len, size);
        if (off >= end)
            return reply_mem(bufp, alloc_aligned(0).release(), 0);
        uint8_t* mem = read_aligned(ws.out.extents, size, off, end);
        const uint64_t s_lo = std::max(off, ws.stage_off);
        const uint64_t s_hi = std::min(end, ws.stage_off + ws.stage_len);
        if (s_lo < s_hi)
            std::memcpy(mem + (s_lo - off), ws.stage.get() + (s_lo - ws.stage_off), s_hi - s_lo);
        return reply_mem(bufp, mem, end - off);
    }

    int write(const char* src, size_t len, off_t offset, fuse_file_info* fi)
    {
        auto* h = reinterpret_cast<Handle*>(fi->fh);
        const auto off = static_cast<uint64_t>(offset);
        const auto* data = reinterpret_cast<const uint8_t*>(src);
        switch (h->kind) {
        case Handle::Kind::CONTROL:
            return write_control(*h, std::string(src, len));
        case Handle::Kind::WRITE: {
            // Data accepted after a failed commit could never be committed, so the writer learns of the failure here.
            if (failed_)
                return -EIO;
            std::lock_guard wl(h->ws->mu);
            write_writer(*h->ws, off, std::span(data, len));
            return static_cast<int>(len);
        }
        case Handle::Kind::READ:
            break;
        }
        return -EBADF;
    }

    void start()
    {
        pool_      = std::make_unique<IoPool>(opts_.io_threads);
        committer_ = std::thread([this] { commit_loop(); });
    }

    void destroy()
    {
        {
            std::lock_guard lock(mu_);
            stopping_ = true;
        }
        commit_cv_.notify_all();
        if (committer_.joinable())
            committer_.join();
        std::lock_guard lock(mu_);
        // An exception must not unwind through libfuse; the volume then stays dirty for --recover.
        try {
            const auto writers = std::move(writers_);
            writers_.clear();
            for (auto& [key, ws] : writers) {
                std::lock_guard wl(ws->mu);
                flush_stage(*ws);
                finish_writer(*ws);
            }
            opens_.clear();
            for (const auto& [key, path] : std::unordered_map(orphans_))
                remove_orphan(key);
            vol_->commit();
        } catch (const std::exception& e) {
            log_failure("unmount left the volume dirty", e);
        }
        try {
            vol_->close();
        } catch (const std::exception& e) {
            log_failure("close failed", e);
        }
        pool_.reset();
    }

    bool direct_io() const { return opts_.direct_io; }

private:
    // stderr is /dev/null once the daemon detached, so failures go to syslog.
    void log_failure(const char* what, const std::exception& e)
    {
        failed_ = true;
        ::syslog(LOG_ERR, "%s: %s", what, e.what());
    }

    void fill_stat(struct stat* st, const std::string& path, const DirEntryInfo& d) const
    {
        std::memset(st, 0, sizeof(*st));
        st->st_uid     = ::getuid();
        st->st_gid     = ::getgid();
        st->st_blksize = IO_SIZE_HINT;
        const time_t t = d.mtime ? static_cast<time_t>(d.mtime) : mount_time_;
        st->st_mtime = st->st_atime = st->st_ctime = t;
        if (d.is_dir) {
            st->st_mode  = S_IFDIR | 0755;
            st->st_nlink = 2;
            return;
        }
        st->st_mode  = S_IFREG | 0644;
        st->st_nlink = 1;
        const auto key = key_of(path);
        uint64_t size = d.unfinished ? 0 : d.size;
        if (auto it = writers_.find(key); it != writers_.end())
            size = it->second->size;
        else if (auto c = closed_.find(key); c != closed_.end())
            size = c->second;
        st->st_size   = static_cast<off_t>(size);
        st->st_blocks = static_cast<blkcnt_t>((size + cluster_ - 1) / cluster_ * (cluster_ / 512));
    }

    void fill_control(struct stat* st) const
    {
        std::memset(st, 0, sizeof(*st));
        st->st_mode  = S_IFREG | 0666;
        st->st_nlink = 1;
        st->st_uid   = ::getuid();
        st->st_gid   = ::getgid();
        st->st_size  = static_cast<off_t>(last_report_.size());
        st->st_mtime = st->st_atime = st->st_ctime = mount_time_;
    }

    void set_cache_flags(fuse_file_info* fi, Handle::Kind kind) const
    {
        fi->direct_io  = opts_.direct_io;
        fi->keep_cache = !opts_.direct_io && kind == Handle::Kind::READ;
    }

    // Caller holds mu_.
    std::shared_ptr<WriteState> add_writer(const std::string& path, Output out, uint64_t size)
    {
        auto ws   = std::make_shared<WriteState>();
        ws->path  = path;
        ws->out   = std::move(out);
        ws->size  = size;
        ws->opens = 1;
        const auto key = key_of(path);
        writers_[key] = ws;
        for (Handle* h : readers_)
            if (h->key == key) {
                std::lock_guard rl(h->ra->mu);
                h->live = ws;
            }
        return ws;
    }

    std::shared_ptr<WriteState> new_writer(const std::string& path) { return add_writer(path, vol_->reserve(path, cluster_), 0); }

    std::shared_ptr<WriteState> reopen_writer(const std::string& path, uint64_t size)
    {
        auto ws      = add_writer(path, vol_->reopen(path), size);
        ws->reopened = true;
        return ws;
    }

    // Drops one handle of the writer (caller holds ws.mu); the last one finalizes the file.
    void close_writer(WriteState& ws)
    {
        flush_stage(ws);
        std::lock_guard lock(mu_);
        if (--ws.opens > 0)
            return;
        writers_.erase(key_of(ws.path));
        finish_writer(ws);
        release_cv_.notify_all();
    }

    // Finalizes a writer whose handles are all gone, or drops it when its name was unlinked meanwhile.
    void finish_writer(WriteState& ws)
    {
        const auto key = key_of(ws.path);
        if (orphans_.count(key) && !ws.reopened) {
            orphans_.erase(key);
            vol_->abandon(ws.out);
            removed_.insert(key);
        } else {
            vol_->finalize(ws.out, ws.size);
            closed_[key] = ws.size;
            refresh_readers(ws);
            remove_orphan(key);
        }
        stage();
    }

    // Read handles opened before the writer would otherwise keep serving the clusters and size they saw at open.
    void refresh_readers(const WriteState& ws)
    {
        const auto key = key_of(ws.path);
        std::optional<FileExtents> fe;
        for (Handle* h : readers_)
            if (h->key == key) {
                if (!fe) {
                    fe = block_extents(vol_->extents(ws.path));
                    fe->size = fe->valid_size = ws.size;
                }
                std::lock_guard rl(h->ra->mu);
                h->fe = *fe;
                h->live.reset();
                h->ra->chunks.clear();
            }
    }

    // ------------------------------------------------------------ open handles and unlinked names (caller holds mu_)

    bool has_handles(const std::string& key) const { return opens_.count(key) || writers_.count(key); }
    bool hidden(const std::string& key) const { return removed_.count(key) || orphans_.count(key); }
    // The volume's own case folding, so these maps match two names exactly when the volume does.
    std::string key_of(const std::string& path) const { return vol_->key(path); }

    void remove_orphan(const std::string& key)
    {
        auto it = orphans_.find(key);
        if (it == orphans_.end() || has_handles(key))
            return;
        const std::string path = it->second;
        orphans_.erase(it);
        settle(key);
        vol_->remove(path);
        removed_.insert(key);
        stage();
    }

    // POSIX lets open handles outlive the name: the file moves to a hidden name, which the last close removes.
    std::string make_orphan(const std::string& path)
    {
        std::string hide;
        do
            hide = ORPHAN_PREFIX + std::to_string(orphan_seq_++);
        while (vol_->exists(hide));
        vol_->rename(path, hide);
        rekey(path, hide);
        orphans_[key_of(hide)] = hide;
        stage();
        return hide;
    }

    // Moves the per-name state of from, and of everything below it, to the same place below to.
    void rekey(const std::string& from, const std::string& to)
    {
        const auto fk = key_of(from);
        const auto tk = key_of(to);
        // Folding can change a name's byte length, so a path's part below from is found by components, not by offset.
        const auto depth = static_cast<size_t>(std::count(from.begin(), from.end(), '/'));
        auto moved_path = [&](const std::string& p) {
            size_t pos = 0;
            for (size_t i = 0; i < depth && pos != std::string::npos; ++i)
                pos = p.find('/', pos + 1);
            return to + (pos == std::string::npos ? std::string() : p.substr(pos));
        };
        auto moved_key  = [&](const std::string& k) { return tk + k.substr(fk.size()); };
        auto rekey_map  = [&](auto& m, auto&& on_value) {
            std::vector<std::string> keys;
            for (const auto& [k, v] : m)
                if (at_or_below(k, fk))
                    keys.push_back(k);
            for (const auto& k : keys) {
                auto node  = m.extract(k);
                node.key() = moved_key(k);
                on_value(node.mapped());
                m.insert(std::move(node));
            }
        };
        auto no_value = [](auto&) {};
        rekey_map(writers_, [&](std::shared_ptr<WriteState>& ws) { ws->path = moved_path(ws->path); });
        rekey_map(opens_, no_value);
        rekey_map(closed_, no_value);
        rekey_map(orphans_, [&](std::string& p) { p = moved_path(p); });
        std::vector<std::string> gone;
        for (const auto& k : removed_)
            if (at_or_below(k, fk))
                gone.push_back(k);
        for (const auto& k : gone) {
            removed_.erase(k);
            removed_.insert(moved_key(k));
        }
        for (Handle* h : readers_)
            if (at_or_below(h->key, fk)) {
                h->key  = moved_key(h->key);
                h->path = moved_path(h->path);
            }
    }

    // ------------------------------------------------------------ group commit (caller holds mu_)

    void stage()
    {
        staged_ = true;
        commit_cv_.notify_one();
    }

    void commit_staged()
    {
        if (!staged_)
            return;
        vol_->commit();
        closed_.clear();
        removed_.clear();
        staged_ = false;
    }

    // The volume refuses to reopen, remove or recreate a name whose finalize or removal is still staged.
    void settle(const std::string& key)
    {
        if (closed_.count(key) || removed_.count(key))
            commit_staged();
    }

    void commit_loop()
    {
        std::unique_lock lock(mu_);
        while (!stopping_) {
            commit_cv_.wait(lock, [&] { return staged_ || stopping_; });
            commit_cv_.wait_for(lock, COMMIT_DELAY, [&] { return stopping_; });
            try {
                commit_staged();
            } catch (const std::exception& e) {
                // The volume now refuses every write with EIO, so retrying would only repeat this line.
                log_failure("commit failed", e);
                staged_ = false;
            }
        }
    }

    // ------------------------------------------------------------ read-ahead
    // Chunks covering [off, end) when the read continues a sequential stream, empty otherwise.
    std::vector<std::shared_ptr<ReadAhead::Chunk>> read_ahead(Handle& h, uint64_t off, uint64_t end)
    {
        auto& ra = *h.ra;
        std::lock_guard lock(ra.mu);
        auto& q = ra.chunks;
        const bool in_window = !q.empty() && off >= q.front()->off && off < q.back()->off + q.back()->len + RA_CHUNK;
        // A first read gets no read-ahead, so small files cost no background I/O.
        const bool sequential = (off == ra.expect && off > 0) || in_window;
        ra.expect = end;
        if (!sequential)
            return {};
        while (!q.empty() && q.front()->off + q.front()->len <= off)
            q.pop_front();
        const uint64_t file_end = align_up(h.fe.size);
        uint64_t next = q.empty() ? off - off % RA_CHUNK : q.back()->off + q.back()->len;
        while (next < file_end && next < end + RA_DEPTH * RA_CHUNK) {
            const uint64_t n = std::min(RA_CHUNK, file_end - next);
            auto c = std::make_shared<ReadAhead::Chunk>();
            c->off = next;
            c->len = n;
            c->buf = alloc_aligned(n);
            c->ready = pool_->submit([this, c, ext = h.fe.extents, valid = h.fe.valid_size] {
                fill_aligned(ext, valid, c->off, c->off + c->len, c->buf.get());
            });
            q.push_back(std::move(c));
            next += n;
        }
        std::vector<std::shared_ptr<ReadAhead::Chunk>> use;
        uint64_t covered = 0;
        for (const auto& c : q)
            if (c->off < end && c->off + c->len > off) {
                use.push_back(c);
                covered += std::min(end, c->off + c->len) - std::max(off, c->off);
            }
        if (covered != end - off)
            return {};
        return use;
    }

    std::string last_report()
    {
        std::lock_guard lock(mu_);
        return last_report_;
    }

    static int reply_mem(fuse_bufvec** bufp, uint8_t* mem, uint64_t n)
    {
        auto* bv = static_cast<fuse_bufvec*>(std::malloc(sizeof(fuse_bufvec)));
        if (!bv) {
            std::free(mem);
            return -ENOMEM;
        }
        *bv = FUSE_BUFVEC_INIT(n);
        bv->buf[0].mem = mem;
        *bufp = bv;
        return 0;
    }

    // File bytes [off, end) of a file whose bytes from valid on read as zero; the buffer goes to libfuse, which frees it.
    uint8_t* read_aligned(const std::vector<Extent>& extents, uint64_t valid, uint64_t off, uint64_t end)
    {
        const uint64_t a_lo = align_down(off);
        AlignedBuf mem(alloc_aligned(align_up(end) - a_lo));
        fill_aligned(extents, valid, a_lo, align_up(end), mem.get());
        if (off != a_lo)
            std::memmove(mem.get(), mem.get() + (off - a_lo), end - off);
        return mem.release();
    }

    // Block-aligned file bytes [a_lo, a_hi) into mem, zero from valid on.
    void fill_aligned(const std::vector<Extent>& extents, uint64_t valid, uint64_t a_lo, uint64_t a_hi, uint8_t* mem)
    {
        const uint64_t v_hi = std::min(a_hi, align_up(valid));
        if (a_lo < v_hi)
            for_each_dev_range(extents, a_lo, v_hi - a_lo, [&](uint64_t dev, uint64_t at, uint64_t n) {
                data_->read(dev, std::span(mem + at, n));
            });
        const uint64_t zero_from = std::max(a_lo, std::min(a_hi, valid));
        if (zero_from < a_hi)
            std::memset(mem + (zero_from - a_lo), 0, a_hi - zero_from);
    }

    // ------------------------------------------------------------ writer internals (caller holds ws.mu)

    void ensure_reserved(WriteState& ws, uint64_t end)
    {
        if (end <= ws.out.reserved_bytes)
            return;
        const uint64_t grow = std::max(end - ws.out.reserved_bytes, std::min(ws.out.reserved_bytes, MAX_GROWTH));
        std::lock_guard lock(mu_);
        vol_->extend(ws.out, grow);
    }

    void dev_write(WriteState& ws, uint64_t off, const uint8_t* src, uint64_t len)
    {
        for_each_dev_range(ws.out.extents, off, len, [&](uint64_t dev, uint64_t at, uint64_t n) {
            data_->write(dev, std::span(src + at, n));
        });
    }

    void drain(WriteState& ws)
    {
        if (!ws.inflight.valid())
            return;
        const auto done = std::move(ws.inflight);
        done.get();
    }

    // Hands a full stage to a background write and continues in the spare buffer.
    void spill_full(WriteState& ws)
    {
        drain(ws);
        struct Piece {
            uint64_t dev, at, n;
        };
        std::vector<Piece> pieces;
        for_each_dev_range(ws.out.extents, ws.stage_off, STAGE_BYTES,
                           [&](uint64_t dev, uint64_t at, uint64_t n) { pieces.push_back({dev, at, n}); });
        std::swap(ws.stage, ws.spare);
        ws.inflight = pool_->submit([this, src = ws.spare.get(), pieces = std::move(pieces)] {
            for (const auto& p : pieces)
                data_->write(p.dev, std::span(src + p.at, p.n));
        });
        ws.stage_off += STAGE_BYTES;
        ws.stage_len = 0;
    }

    // Writes the stage's whole blocks and keeps the partial last block staged.
    void spill(WriteState& ws)
    {
        const uint64_t whole = align_down(ws.stage_len);
        if (whole == 0)
            return;
        dev_write(ws, ws.stage_off, ws.stage.get(), whole);
        const uint64_t rest = ws.stage_len - whole;
        std::memmove(ws.stage.get(), ws.stage.get() + whole, rest);
        ws.stage_off += whole;
        ws.stage_len = rest;
    }

    void flush_stage(WriteState& ws)
    {
        drain(ws);
        spill(ws);
        if (ws.stage_len == 0)
            return;
        uint8_t* blk = ws.stage.get();
        if (ws.stage_off + ws.stage_len < ws.size) {
            // Bytes past the stage in this block were written earlier and live on the device.
            AlignedBuf old(alloc_aligned(IO_ALIGN));
            for_each_dev_range(ws.out.extents, ws.stage_off, IO_ALIGN, [&](uint64_t dev, uint64_t at, uint64_t n) {
                data_->read(dev, std::span(old.get() + at, n));
            });
            std::memcpy(blk + ws.stage_len, old.get() + ws.stage_len, IO_ALIGN - ws.stage_len);
        } else {
            std::memset(blk + ws.stage_len, 0, IO_ALIGN - ws.stage_len);
        }
        dev_write(ws, ws.stage_off, blk, IO_ALIGN);
        ws.stage_len = 0;
    }

    // Starts the stage at the block holding off, loading the block's earlier bytes from the device.
    void restart_stage(WriteState& ws, uint64_t off)
    {
        flush_stage(ws);
        ws.stage_off = align_down(off);
        ws.stage_len = off - ws.stage_off;
        if (ws.stage_len == 0)
            return;
        if (ws.stage_off < ws.size)
            for_each_dev_range(ws.out.extents, ws.stage_off, IO_ALIGN, [&](uint64_t dev, uint64_t at, uint64_t n) {
                data_->read(dev, std::span(ws.stage.get() + at, n));
            });
        const uint64_t keep = ws.size > ws.stage_off ? ws.size - ws.stage_off : 0;
        if (keep < ws.stage_len)
            std::memset(ws.stage.get() + keep, 0, ws.stage_len - keep);
    }

    void write_writer(WriteState& ws, uint64_t off, std::span<const uint8_t> data)
    {
        ensure_reserved(ws, off + data.size());
        if (off > ws.size) {
            static const std::vector<uint8_t> zeros(STAGE_BYTES, 0);
            for (uint64_t pos = ws.size; pos < off;) {
                const uint64_t n = std::min<uint64_t>(zeros.size(), off - pos);
                write_writer(ws, pos, std::span(zeros.data(), n));
                pos += n;
            }
        }
        uint64_t pos = off;
        size_t   done = 0;
        while (done < data.size()) {
            const uint64_t s_end = ws.stage_off + ws.stage_len;
            if (pos < ws.stage_off || pos > s_end || (ws.stage_len == 0 && pos != ws.stage_off))
                restart_stage(ws, pos);
            else if (pos == s_end && ws.stage_len == STAGE_BYTES)
                spill_full(ws);
            const uint64_t at = pos - ws.stage_off;
            const uint64_t n  = std::min<uint64_t>(data.size() - done, STAGE_BYTES - at);
            std::memcpy(ws.stage.get() + at, data.data() + done, n);
            ws.stage_len = std::max(ws.stage_len, at + n);
            pos += n;
            done += n;
            if (ws.stage_len == STAGE_BYTES)
                spill_full(ws);
        }
        ws.size = std::max<uint64_t>(ws.size, off + data.size());
    }

    void truncate_writer(WriteState& ws, uint64_t size)
    {
        drain(ws);
        if (size > ws.size) {
            static const std::vector<uint8_t> none;
            write_writer(ws, size, std::span(none.data(), 0));
            return;
        }
        ws.size = size;
        if (ws.stage_off + ws.stage_len > size)
            ws.stage_len = size > ws.stage_off ? size - ws.stage_off : 0;
    }

    // ------------------------------------------------------------ jobs

    int write_control(Handle& h, const std::string& text)
    {
        h.ctl_in += text;
        bool ok = true;
        for (size_t nl; (nl = h.ctl_in.find('\n')) != std::string::npos;) {
            const std::string line = h.ctl_in.substr(0, nl);
            h.ctl_in.erase(0, nl + 1);
            std::istringstream ss(line);
            std::vector<std::string> args;
            for (std::string t; ss >> t;)
                args.push_back(t);
            if (args.empty())
                continue;
            if (args[0] == "run")
                args.erase(args.begin());
            try {
                h.ctl_out = run_job(args, ok);
            } catch (const std::exception& e) {
                h.ctl_out = std::string("job failed: ") + e.what() + "\n";
                ok = false;
            }
            std::lock_guard lock(mu_);
            last_report_ = h.ctl_out;
        }
        return ok ? static_cast<int>(text.size()) : -EIO;
    }

    std::string run_job(const std::vector<std::string>& args, bool& ok)
    {
        const auto run = parse_digest_fill_run(args);
        if (!run.card.empty())
            throw std::invalid_argument("the card is chosen when mounting");
        std::lock_guard jl(job_mu_);
        std::vector<std::string> busy;
        std::vector<Output> outs;
        {
            std::unique_lock lock(mu_);
            auto writing = [&] {
                for (const auto& s : run.streams)
                    for (size_t i = 1; i < s.size(); ++i)
                        if (writers_.count(key_of(s[i])))
                            return s[i];
                return std::string();
            };
            release_cv_.wait_for(lock, RELEASE_GRACE, [&] { return writing().empty(); });
            if (const auto w = writing(); !w.empty())
                fail(std::errc::device_or_resource_busy, w + " is still being written");
            commit_staged();
            outs = reserve_digest_fill_outputs(*vol_, run);
            for (const auto& s : run.streams)
                for (const auto& p : s)
                    if (job_busy_[key_of(p)]++ == 0)
                        busy.push_back(key_of(p));
        }
        std::string report;
        {
            JobResult res;
            try {
                res = run_digest_fill(*vol_, run, outs, card_.get(), model_dev_.get(), &mu_);
            } catch (...) {
                release_busy(busy);
                throw;
            }
            std::lock_guard lock(mu_);
            vol_->commit();
            report = digest_fill_report(*vol_, run, res);
            if (!res.ok)
                report += "job failed: " + res.error + "\n";
            ok = res.ok;
            for (const auto& k : busy)
                if (--job_busy_[k] == 0)
                    job_busy_.erase(k);
        }
        // Outputs were written by the card behind the kernel's back.
        for (const auto& s : run.streams)
            fuse_invalidate_path(fuse_get_context()->fuse, s[0].c_str());
        return report;
    }

    void release_busy(const std::vector<std::string>& busy)
    {
        std::lock_guard lock(mu_);
        for (const auto& k : busy)
            if (--job_busy_[k] == 0)
                job_busy_.erase(k);
    }

    [[noreturn]] static void fail(std::errc code, const std::string& what)
    {
        throw std::system_error(std::make_error_code(code), what);
    }

    Options                      opts_;
    std::mutex                   mu_;
    std::unique_ptr<Volume>      vol_;
    std::unique_ptr<BlockDevice> data_;
    std::unique_ptr<BlockDevice> model_dev_;
    std::unique_ptr<MiBus>       card_;
    std::mutex                   job_mu_;
    uint32_t                     cluster_    = 0;
    uint32_t                     clusters_   = 0;
    time_t                       mount_time_ = 0;
    std::unordered_map<std::string, std::shared_ptr<WriteState>> writers_;
    std::unordered_map<std::string, int>                         opens_;
    std::unordered_map<std::string, int>                         job_busy_;
    std::string                                                  last_report_;
    // Staged finalizes (key -> size) and removals that the next commit makes durable.
    std::unordered_map<std::string, uint64_t>                    closed_;
    std::unordered_set<std::string>                              removed_;
    bool                                                         staged_   = false;
    bool                                                         stopping_ = false;
    std::atomic<bool>                                            failed_ {false};
    std::unordered_map<std::string, std::string>                 orphans_;
    uint64_t                                                     orphan_seq_ = 0;
    std::unordered_set<Handle*>                                  readers_;
    std::condition_variable                                      commit_cv_;
    std::condition_variable                                      release_cv_;
    std::thread                                                  committer_;
    std::unique_ptr<IoPool>                                      pool_;
};

Fs& fs() { return *static_cast<Fs*>(fuse_get_context()->private_data); }

int errno_of(const std::exception& e)
{
    if (const auto* se = dynamic_cast<const std::system_error*>(&e))
        if (se->code().category() == std::generic_category() || se->code().category() == std::system_category())
            return se->code().value();
    if (dynamic_cast<const std::invalid_argument*>(&e))
        return EINVAL;
    if (dynamic_cast<const std::bad_alloc*>(&e))
        return ENOMEM;
    return EIO;
}

template <class Fn>
int guarded(Fn fn)
{
    try {
        return fn();
    } catch (const std::exception& e) {
        return -errno_of(e);
    }
}

const fuse_operations OPS = [] {
    fuse_operations ops {};
    ops.init = [](fuse_conn_info* conn, fuse_config* cfg) -> void* {
        cfg->use_ino          = 0;
        cfg->hard_remove      = 1;
        cfg->entry_timeout    = 1.0;
        cfg->attr_timeout     = 1.0;
        cfg->negative_timeout = 0.0;
        cfg->kernel_cache     = !fs().direct_io();
        cfg->direct_io        = fs().direct_io();
        conn->max_write       = IO_SIZE_HINT;
        conn->want           |= FUSE_CAP_ATOMIC_O_TRUNC;
        // Threads started before fuse_daemonize() would not survive its fork.
        fs().start();
        return fuse_get_context()->private_data;
    };
    ops.destroy = [](void* p) { static_cast<Fs*>(p)->destroy(); };
    ops.getattr = [](const char* path, struct stat* st, fuse_file_info* fi) {
        return guarded([&] { return fs().getattr(path, st, fi); });
    };
    ops.readdir = [](const char* path, void* buf, fuse_fill_dir_t filler, off_t, fuse_file_info*, fuse_readdir_flags f) {
        return guarded([&] { return fs().readdir(path, buf, filler, f); });
    };
    ops.mkdir  = [](const char* path, mode_t) { return guarded([&] { return fs().mkdir(path); }); };
    ops.unlink = [](const char* path) { return guarded([&] { return fs().remove(path); }); };
    ops.rmdir  = [](const char* path) { return guarded([&] { return fs().remove(path); }); };
    ops.rename   = [](const char* from, const char* to, unsigned int flags) {
        return guarded([&] { return fs().rename(from, to, flags); });
    };
    ops.link     = [](const char*, const char*) { return -EPERM; };
    ops.symlink  = [](const char*, const char*) { return -EPERM; };
    // exFAT keeps no owner or mode, so tools that copy them must not fail.
    ops.chmod    = [](const char*, mode_t, fuse_file_info*) { return 0; };
    ops.chown    = [](const char*, uid_t, gid_t, fuse_file_info*) { return 0; };
    ops.utimens  = [](const char*, const struct timespec*, fuse_file_info*) { return 0; };
    ops.statfs   = [](const char*, struct statvfs* sv) { return guarded([&] { return fs().statfs(sv); }); };
    ops.open     = [](const char* path, fuse_file_info* fi) { return guarded([&] { return fs().open(path, fi); }); };
    ops.create   = [](const char* path, mode_t, fuse_file_info* fi) {
        return guarded([&] { return fs().create(path, fi); });
    };
    ops.release  = [](const char*, fuse_file_info* fi) { return guarded([&] { return fs().release(fi); }); };
    ops.fsync    = [](const char*, int, fuse_file_info* fi) { return guarded([&] { return fs().fsync(fi); }); };
    ops.fsyncdir = [](const char*, int, fuse_file_info*) { return guarded([&] { return fs().fsyncdir(); }); };
    ops.truncate = [](const char* path, off_t size, fuse_file_info* fi) {
        return guarded([&] { return fs().truncate(path, size, fi); });
    };
    ops.fallocate = [](const char*, int mode, off_t off, off_t len, fuse_file_info* fi) {
        return guarded([&] { return fs().fallocate(mode, off, len, fi); });
    };
    ops.read_buf = [](const char*, fuse_bufvec** bufp, size_t len, off_t off, fuse_file_info* fi) {
        return guarded([&] { return fs().read_buf(bufp, len, off, fi); });
    };
    ops.write = [](const char*, const char* buf, size_t len, off_t off, fuse_file_info* fi) {
        return guarded([&] { return fs().write(buf, len, off, fi); });
    };
    return ops;
}();

void usage()
{
    std::fprintf(stderr,
        "usage: iuv-fs [options] <device> <mountpoint>\n"
        "  --drives N        drives of the RAID0 stripe (4)\n"
        "  --chunk-kib K     stripe chunk in KiB (128)\n"
        "  --card DEV        run jobs on this card; without it they run on the software model\n"
        "  --compatible C    device tree compatible of the file shell\n"
        "  --direct-io       bypass the kernel page cache\n"
        "  --discard         discard the clusters of removed and truncated files\n"
        "  --threads N       FUSE worker threads (16)\n"
        "  --io-threads N    background read-ahead and write threads (4)\n"
        "  --recover         clean up a dirty volume before mounting\n"
        "  -f, -d, -o OPT    foreground, debug, FUSE mount option\n"
        "jobs: write '[run] <iuv-exfat run arguments without --card>' to <mountpoint>/.iuv-job;\n"
        "      the write fails with EIO when the job fails, and reading the file returns the report\n");
}

} // namespace

int main(int argc, char** argv)
{
    Options o;
    std::vector<std::string> pos;
    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        auto next = [&]() -> std::string {
            if (i + 1 >= argc)
                throw std::invalid_argument(a + " needs a value");
            return argv[++i];
        };
        try {
            if (a == "--drives")
                o.drives = static_cast<uint32_t>(parse_u64(next(), UINT32_MAX));
            else if (a == "--chunk-kib")
                o.chunk_kib = static_cast<uint32_t>(parse_u64(next(), UINT32_MAX / 1024));
            else if (a == "--card")
                o.card = next();
            else if (a == "--compatible")
                o.compatible = next();
            else if (a == "--direct-io")
                o.direct_io = true;
            else if (a == "--discard")
                o.discard = true;
            else if (a == "--threads")
                o.threads = static_cast<uint32_t>(parse_u64(next(), UINT32_MAX));
            else if (a == "--io-threads")
                o.io_threads = std::max(1u, static_cast<uint32_t>(parse_u64(next(), UINT32_MAX)));
            else if (a == "--recover")
                o.recover = true;
            else if (a == "-f")
                o.foreground = true;
            else if (a == "-d")
                o.debug = o.foreground = true;
            else if (a == "-o")
                o.fuse_opts.push_back(next());
            else if (a == "-h" || a == "--help") {
                usage();
                return 0;
            } else
                pos.push_back(a);
        } catch (const std::exception& e) {
            std::fprintf(stderr, "iuv-fs: %s\n", e.what());
            return 2;
        }
    }
    if (pos.size() != 2) {
        usage();
        return 2;
    }
    o.device     = pos[0];
    o.mountpoint = pos[1];
    // Request and stage buffers of megabytes would otherwise be mmapped and page-faulted in on every request.
    mallopt(M_MMAP_THRESHOLD, 16 << 20);
    mallopt(M_TRIM_THRESHOLD, 32 << 20);

    ::openlog("iuv-fs", LOG_PID | LOG_PERROR, LOG_DAEMON);
    std::unique_ptr<Fs> fsys;
    try {
        fsys = std::make_unique<Fs>(o);
    } catch (const std::exception& e) {
        std::fprintf(stderr, "iuv-fs: %s\n", e.what());
        return 1;
    }

    fuse_args args = FUSE_ARGS_INIT(0, nullptr);
    fuse_opt_add_arg(&args, argv[0]);
    if (o.debug)
        fuse_opt_add_arg(&args, "-d");
    for (const auto& opt : o.fuse_opts) {
        fuse_opt_add_arg(&args, "-o");
        fuse_opt_add_arg(&args, opt.c_str());
    }
    fuse* f = fuse_new(&args, &OPS, sizeof(OPS), fsys.get());
    fuse_opt_free_args(&args);
    if (!f)
        return 1;
    int rc = 1;
    if (fuse_mount(f, o.mountpoint.c_str()) == 0) {
        fuse_session* se = fuse_get_session(f);
        if (fuse_set_signal_handlers(se) == 0) {
            if (fuse_daemonize(o.foreground) == 0) {
                fuse_loop_config* cfg = fuse_loop_cfg_create();
                fuse_loop_cfg_set_max_threads(cfg, o.threads);
                rc = fuse_loop_mt(f, cfg) == 0 ? 0 : 1;
                fuse_loop_cfg_destroy(cfg);
            }
            fuse_remove_signal_handlers(se);
        }
        fuse_unmount(f);
    }
    fuse_destroy(f);
    return rc;
}
