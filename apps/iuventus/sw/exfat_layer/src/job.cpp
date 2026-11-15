// job.cpp: file shell job submission, NEED_SPACE service and completion over MI
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#include "iuv_exfat/job.hpp"

#include <array>
#include <bit>
#include <deque>
#include <stdexcept>
#include <system_error>
#include <thread>

#include "error.hpp"

namespace iuv_exfat {

namespace {

constexpr uint64_t REG_CTRL        = 0x00;
constexpr uint64_t REG_STATUS      = 0x04;
constexpr uint64_t REG_STREAM_MASK = 0x08;
constexpr uint64_t REG_VERSION     = 0x0C;
constexpr uint64_t REG_RING_DEPTHS = 0x10;
constexpr uint64_t REG_KERNEL_ID   = 0x14;
constexpr uint64_t REG_STRIPE      = 0x18;

constexpr uint64_t STREAM_BASE   = 0x100;
constexpr uint64_t STREAM_STRIDE = 0x40;
constexpr uint64_t S_IN_FILES    = 0x00;
constexpr uint64_t S_IN_TAIL     = 0x08;
constexpr uint64_t S_IN_HEAD     = 0x0C;
constexpr uint64_t S_OUT_TAIL    = 0x10;
constexpr uint64_t S_OUT_HEAD    = 0x14;
constexpr uint64_t S_OUT_BYTES   = 0x18;
constexpr uint64_t S_STATUS      = 0x20;
constexpr uint64_t S_ERR_INFO    = 0x24;
constexpr uint64_t S_IN_BYTES    = 0x28;

constexpr uint64_t ARGS_BASE       = 0x1000;
constexpr uint64_t ARGS_STRIDE     = 0x200;
constexpr uint64_t OUT_RING_BASE   = 0x0800000;
constexpr uint64_t OUT_RING_STRIDE = 0x40000;
constexpr uint64_t IN_RING_BASE    = 0x1000000;
constexpr uint64_t IN_RING_STRIDE  = 0x100000;
constexpr uint64_t ENTRY_BYTES     = 16;

constexpr uint32_t CTRL_START = 1u << 0;
constexpr uint32_t CTRL_ABORT = 1u << 1;
constexpr uint32_t CTRL_CLEAR = 1u << 2;

constexpr uint32_t ST_BUSY       = 1u << 0;
constexpr uint32_t ST_DONE       = 1u << 1;
constexpr uint32_t ST_ERR        = 1u << 2;
constexpr uint32_t ST_NEED_SPACE = 1u << 3;

constexpr uint32_t SS_NEED_SPACE = 1u << 2;
constexpr uint32_t SS_ERR        = 1u << 3;

constexpr uint32_t ENTRY_EXTENT = 0;
constexpr uint32_t ENTRY_FILE   = 1;
constexpr uint32_t ENTRY_LAST   = 1u << 31;

constexpr uint32_t LAYOUT_VERSION = 1;

using RingEntry = std::array<uint32_t, 4>;

uint64_t sreg(uint32_t s, uint64_t reg) { return STREAM_BASE + s * STREAM_STRIDE + reg; }

RingEntry extent_entry(const Extent& e)
{
    return {static_cast<uint32_t>(e.lba), static_cast<uint32_t>(e.lba >> 32) & 0xFFFF, e.count, ENTRY_EXTENT};
}

} // namespace

std::string describe_err_info(uint32_t info)
{
    const uint32_t source = (info >> 8) & 0xF;
    const uint32_t index  = info >> 16;
    switch (source) {
    case 0: {
        static const char* const CODES[] = {"success", "generic status", "LBA out of range", "data lost"};
        std::string s = std::string((info & 4) ? "read" : "write") + " failed: NVMe " + CODES[info & 3] + " (code " +
                        std::to_string(info & 3) + ")";
        if ((info & 3) != 2)
            s += " on drive " + std::to_string((info >> 4) & 0xF) + ", CID " + std::to_string(index);
        return s;
    }
    case 1:
        // The shell reports the entry number in 16 bits, so 0 is START (never an input list) or an entry that is a multiple of 65536.
        if (index == 0)
            return (info & 4) ? std::string("format error in input list entry 65536 * k")
                              : std::string("format error at START (STRIPE or kernel arguments) or at output ring entry 65536 * k");
        return std::string("format error in ") + ((info & 4) ? "input list" : "output ring") + " entry " +
               std::to_string(index) + " (modulo 65536)";
    case 2:
        return "aborted";
    case 3:
        return "non-OKAY HBM response on the ring port";
    default:
        return "unknown error source " + std::to_string(source);
    }
}

std::vector<uint32_t> digest_fill_args(uint64_t fill_bytes, uint32_t seed)
{
    if (fill_bytes % 64 != 0)
        throw std::invalid_argument("DIGEST_FILL FILL_BYTES must be a multiple of 64");
    return {static_cast<uint32_t>(fill_bytes), static_cast<uint32_t>(fill_bytes >> 32), seed};
}

struct Job::Impl {
    struct Stream {
        std::vector<std::string> inputs;
        Output*                  output = nullptr;
        std::vector<uint32_t>    args;
        std::vector<RingEntry>   in_entries;
        uint64_t                 in_tail = 0;
        std::deque<Extent>       out_pending;
        uint64_t                 out_tail = 0;
        StreamResult             res;
    };

    Impl(MiBus& b, Volume& v, JobOptions o) : bus(b), vol(v), opts(std::move(o)) {}

    MiBus&              bus;
    Volume&             vol;
    JobOptions          opts;
    std::vector<Stream> streams;
    uint64_t            in_cap    = 0;
    uint64_t            out_cap   = 0;
    bool                submitted = false;
    bool                finished  = false;

    std::unique_lock<std::mutex> lock_volume()
    {
        return opts.volume_mutex ? std::unique_lock(*opts.volume_mutex) : std::unique_lock<std::mutex>();
    }

    uint64_t read64(uint64_t reg)
    {
        const uint64_t lo = bus.read32(reg);
        return lo | (static_cast<uint64_t>(bus.read32(reg + 4)) << 32);
    }

    // Fills the free slots of one ring from take(), then publishes the new tail.
    template <class Pending, class Take>
    void push_ring(uint32_t s, uint64_t ring_base, uint64_t ring_stride, uint64_t head_reg, uint64_t tail_reg, uint64_t cap,
                   uint64_t& tail, Pending pending, Take take)
    {
        if (!pending())
            return;
        const uint64_t head = bus.read32(sreg(s, head_reg));
        const uint64_t used = (tail - head) & 0xFFFFFFFFu;
        uint64_t free = used < cap ? cap - used : 0;
        const uint64_t before = tail;
        while (free-- > 0 && pending()) {
            const RingEntry ent  = take();
            const uint64_t  slot = tail % cap;
            for (int w = 0; w < 4; ++w)
                bus.write32(ring_base + s * ring_stride + slot * ENTRY_BYTES + 4 * w, ent[w]);
            ++tail;
        }
        if (tail != before)
            bus.write32(sreg(s, tail_reg), static_cast<uint32_t>(tail));
    }

    void push_inputs(uint32_t s)
    {
        auto& st = streams[s];
        push_ring(s, IN_RING_BASE, IN_RING_STRIDE, S_IN_HEAD, S_IN_TAIL, in_cap, st.in_tail,
                  [&] { return st.in_tail < st.in_entries.size(); }, [&] { return st.in_entries[st.in_tail]; });
    }

    void push_outputs(uint32_t s)
    {
        auto& st = streams[s];
        push_ring(s, OUT_RING_BASE, OUT_RING_STRIDE, S_OUT_HEAD, S_OUT_TAIL, out_cap, st.out_tail,
                  [&] { return !st.out_pending.empty(); },
                  [&] {
                      const Extent e = st.out_pending.front();
                      st.out_pending.pop_front();
                      return extent_entry(e);
                  });
    }

    bool wait_not_busy()
    {
        const auto deadline = std::chrono::steady_clock::now() + opts.timeout;
        while (bus.read32(REG_STATUS) & ST_BUSY) {
            if (std::chrono::steady_clock::now() > deadline)
                return false;
            if (opts.poll_interval.count() > 0)
                std::this_thread::sleep_for(opts.poll_interval);
        }
        return true;
    }

    // Clusters are freed only once the shell is idle, so no in-flight write can land in them after reuse.
    JobResult fail_all(const std::string& why)
    {
        if (!wait_not_busy())
            throw std::runtime_error(why + "; the shell stays BUSY, outputs left reserved for recover()");
        JobResult r;
        r.error = why;
        const auto lock = lock_volume();
        for (auto& st : streams) {
            vol.abandon(*st.output);
            r.streams.push_back(st.res);
        }
        finished = true;
        return r;
    }
};

Job::Job(MiBus& bus, Volume& volume, JobOptions opts) : impl_(std::make_unique<Impl>(bus, volume, std::move(opts))) {}

Job::~Job() = default;

void Job::add_stream(std::vector<std::string> inputs, Output& output, std::vector<uint32_t> kernel_args)
{
    if (impl_->submitted)
        throw std::logic_error("add_stream after submit");
    if (impl_->streams.size() >= MAX_STREAMS)
        throw std::invalid_argument("more than " + std::to_string(MAX_STREAMS) + " streams");
    if (inputs.empty())
        throw std::invalid_argument("a stream needs at least one input file");
    if (kernel_args.size() > ARGS_STRIDE / 4)
        throw std::invalid_argument("kernel arguments exceed the 512 B stream window");
    Impl::Stream st;
    st.inputs = std::move(inputs);
    st.output = &output;
    st.args   = std::move(kernel_args);
    impl_->streams.push_back(std::move(st));
}

void Job::submit()
{
    auto& im = *impl_;
    if (im.submitted)
        throw std::logic_error("job already submitted");
    if (im.streams.empty())
        throw std::invalid_argument("job without streams");
    auto lock = im.lock_volume();
    if (!im.vol.reservations_flushed())
        fail(std::errc::operation_not_permitted, "output reservations are not flushed: call Volume::flush() before submit()");
    if (const uint32_t v = im.bus.read32(REG_VERSION); v != LAYOUT_VERSION)
        throw std::runtime_error("file shell layout version " + std::to_string(v) + ", expected " + std::to_string(LAYOUT_VERSION));
    if (const uint32_t k = im.bus.read32(REG_KERNEL_ID); k != im.opts.kernel_id)
        throw std::runtime_error("file shell kernel " + std::to_string(k) + ", expected " + std::to_string(im.opts.kernel_id));
    const uint32_t depths = im.bus.read32(REG_RING_DEPTHS);
    im.in_cap  = 1ull << (depths & 0xFF);
    im.out_cap = 1ull << ((depths >> 8) & 0xFF);

    for (auto& st : im.streams) {
        for (size_t f = 0; f < st.inputs.size(); ++f) {
            const auto fe = im.vol.extents(st.inputs[f]);
            if (fe.valid_size != fe.size)
                throw std::runtime_error(st.inputs[f] + ": ValidDataLength below DataLength is not readable by the shell");
            st.in_entries.push_back({static_cast<uint32_t>(fe.size), static_cast<uint32_t>(fe.size >> 32),
                                     static_cast<uint32_t>(f), ENTRY_FILE});
            for (const auto& e : fe.extents) {
                if (e.lba >> 48)
                    throw std::runtime_error("LBA beyond 48 bits");
                st.in_entries.push_back(extent_entry(e));
            }
        }
        st.in_entries.back()[3] |= ENTRY_LAST;
        st.out_pending.assign(st.output->extents.begin(), st.output->extents.end());
    }
    const auto vo = im.vol.options();
    lock = {};

    // CLEAR of a job left running drains it first; until then the shell ignores MASK, STRIPE and START.
    im.bus.write32(REG_CTRL, CTRL_CLEAR);
    if (!im.wait_not_busy())
        throw std::runtime_error("the file shell stays BUSY after CLEAR");
    uint32_t mask = 0;
    for (uint32_t s = 0; s < im.streams.size(); ++s) {
        im.push_inputs(s);
        im.push_outputs(s);
        for (size_t w = 0; w < im.streams[s].args.size(); ++w)
            im.bus.write32(ARGS_BASE + s * ARGS_STRIDE + 4 * w, im.streams[s].args[w]);
        mask |= 1u << s;
    }
    const uint32_t log2_drives = static_cast<uint32_t>(std::countr_zero(vo.drives));
    const uint32_t log2_chunk  = static_cast<uint32_t>(std::countr_zero(vo.chunk_bytes / LBA_BYTES));
    im.bus.write32(REG_STRIPE, log2_drives | (log2_chunk << 8));
    im.bus.write32(REG_STREAM_MASK, mask);
    im.bus.write32(REG_CTRL, CTRL_START);
    im.submitted = true;
}

JobResult Job::wait()
{
    auto& im = *impl_;
    if (!im.submitted || im.finished)
        throw std::logic_error("wait() without a running job");
    using clock = std::chrono::steady_clock;
    // Each poll is a non-posted MMIO read per register; a long job backs off to MAX_POLL and checks progress rarely.
    constexpr auto FAST_POLL_FOR  = std::chrono::milliseconds(1);
    constexpr auto MAX_POLL       = std::chrono::microseconds(1000);
    constexpr auto PROGRESS_EVERY = std::chrono::microseconds(100000);
    const auto start            = clock::now();
    const auto progress_every   = std::min<std::chrono::microseconds>(PROGRESS_EVERY, im.opts.timeout / 4);
    const auto max_pause        = std::min<std::chrono::microseconds>(std::max(im.opts.poll_interval, MAX_POLL), progress_every);
    auto       deadline         = start + im.opts.timeout;
    auto       next_progress    = start;
    auto       pause            = im.opts.poll_interval;
    const auto n = static_cast<uint32_t>(im.streams.size());
    uint64_t progress = 0;
    for (;;) {
        const uint32_t status = im.bus.read32(REG_STATUS);
        if (status & ST_ERR) {
            std::string why = "file shell error:";
            for (uint32_t s = 0; s < n; ++s) {
                auto& r    = im.streams[s].res;
                r.status   = im.bus.read32(sreg(s, S_STATUS));
                r.failed   = (r.status & SS_ERR) != 0;
                if (r.failed) {
                    r.err_info = im.bus.read32(sreg(s, S_ERR_INFO));
                    r.err_text = describe_err_info(r.err_info);
                    why += " stream " + std::to_string(s) + ": " + r.err_text + ";";
                }
            }
            return im.fail_all(why);
        }
        if (status & ST_DONE) {
            JobResult r;
            r.ok = true;
            for (uint32_t s = 0; s < n; ++s) {
                auto& st = im.streams[s];
                st.res.status    = im.bus.read32(sreg(s, S_STATUS));
                st.res.in_files  = im.bus.read32(sreg(s, S_IN_FILES));
                st.res.out_bytes = im.read64(sreg(s, S_OUT_BYTES));
                st.res.in_bytes  = im.read64(sreg(s, S_IN_BYTES));
            }
            const auto lock = im.lock_volume();
            for (auto& st : im.streams) {
                if (st.res.out_bytes > st.output->reserved_bytes) {
                    for (auto& other : im.streams)
                        im.vol.abandon(*other.output);
                    im.finished = true;
                    r.ok    = false;
                    r.error = "OUT_BYTES beyond the reservation of " + st.output->path;
                    for (auto& s2 : im.streams)
                        r.streams.push_back(s2.res);
                    return r;
                }
            }
            for (auto& st : im.streams) {
                im.vol.finalize(*st.output, st.res.out_bytes);
                r.streams.push_back(st.res);
            }
            im.finished = true;
            return r;
        }
        if (!(status & ST_BUSY))
            return im.fail_all("file shell went idle without DONE or ERR");
        for (uint32_t s = 0; s < n; ++s) {
            im.push_inputs(s);
            auto& st = im.streams[s];
            if ((status & ST_NEED_SPACE) && st.out_pending.empty() &&
                (im.bus.read32(sreg(s, S_STATUS)) & SS_NEED_SPACE) &&
                im.bus.read32(sreg(s, S_OUT_HEAD)) == static_cast<uint32_t>(st.out_tail)) {
                try {
                    auto lock = im.lock_volume();
                    const auto added = im.vol.extend(*st.output, im.opts.extend_bytes);
                    lock = {};
                    st.out_pending.insert(st.out_pending.end(), added.begin(), added.end());
                    ++st.res.extensions;
                } catch (const std::system_error& e) {
                    im.bus.write32(REG_CTRL, CTRL_ABORT);
                    return im.fail_all(std::string("cannot extend ") + st.output->path + ": " + e.what());
                }
            }
            im.push_outputs(s);
        }
        const auto now = clock::now();
        // The timeout bounds a stall, not the job, so any byte moved restarts it; low words suffice to see a change.
        if (now >= next_progress) {
            next_progress = now + progress_every;
            uint64_t now_progress = 0;
            for (uint32_t s = 0; s < n; ++s)
                now_progress += im.bus.read32(sreg(s, S_IN_BYTES)) + uint64_t {im.bus.read32(sreg(s, S_OUT_BYTES))};
            if (now_progress != progress) {
                progress = now_progress;
                deadline = now + im.opts.timeout;
            }
        }
        if (now > deadline) {
            im.bus.write32(REG_CTRL, CTRL_ABORT);
            return im.fail_all("job timed out");
        }
        if (pause.count() > 0) {
            std::this_thread::sleep_for(pause);
            // A stalled output costs throughput, so NEED_SPACE goes back to fast polling.
            pause = (status & ST_NEED_SPACE) || now - start < FAST_POLL_FOR ? im.opts.poll_interval : std::min(pause * 2, max_pause);
        }
    }
}

} // namespace iuv_exfat
