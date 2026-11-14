// file_shell_model.cpp: software model of the Iuventus file shell running DIGEST_FILL
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#include "iuv_exfat/file_shell_model.hpp"

#include <algorithm>
#include <array>
#include <deque>
#include <random>
#include <vector>

#include "exfat_format.hpp"

namespace iuv_exfat {

namespace {

// Decoded independently of Job on purpose: the model is the reference Job is tested against.
constexpr uint64_t M_CTRL        = 0x00;
constexpr uint64_t M_STATUS      = 0x04;
constexpr uint64_t M_MASK        = 0x08;
constexpr uint64_t M_VERSION     = 0x0C;
constexpr uint64_t M_DEPTHS      = 0x10;
constexpr uint64_t M_KERNEL      = 0x14;
constexpr uint64_t M_STRIPE      = 0x18;
constexpr uint64_t M_STREAM_LO   = 0x100;
constexpr uint64_t M_STREAM_HI   = 0x300;
constexpr uint64_t M_ARGS_LO     = 0x1000;
constexpr uint64_t M_ARGS_HI     = 0x2000;
constexpr uint64_t M_OUT_LO      = 0x0800000;
constexpr uint64_t M_OUT_HI      = 0x0A00000;
constexpr uint64_t M_IN_LO       = 0x1000000;
constexpr uint64_t M_IN_HI       = 0x1800000;
constexpr uint64_t M_STREAM_STRIDE = 0x40;
constexpr uint64_t M_ARGS_STRIDE   = 0x200;
constexpr uint64_t M_OUT_STRIDE    = 0x40000;
constexpr uint64_t M_IN_STRIDE     = 0x100000;
constexpr uint32_t ENTRY_WORDS   = 4;
constexpr uint32_t NSTREAMS      = 8;
constexpr uint32_t MAX_CHUNK_LBAS = 256;
constexpr uint32_t RECORD_BYTES  = 32;
constexpr uint32_t RECORD_MAGIC  = 0x31474944;

constexpr uint32_t SRC_NVME      = 0;
constexpr uint32_t SRC_FORMAT    = 1;
constexpr uint32_t SRC_ABORT     = 2;
constexpr uint32_t SRC_HBM       = 3;
constexpr uint32_t RESERVED_W3   = 0x7FFFFFFCu;
// FS_CTRL drains a running job on CLEAR before it returns to IDLE; BUSY holds for this many STATUS reads.
constexpr uint32_t DRAIN_STATUS_READS = 3;
// FS_CTRL's geometry check rejects a one-LBA chunk.
constexpr uint32_t MIN_LOG2_CHUNK  = 1;
constexpr uint32_t MAX_LOG2_CHUNK  = 8;
constexpr uint32_t MAX_LOG2_DRIVES = 2;

// FS_CTRL's encoding in STATUS[15:8].
enum class State : uint32_t { IDLE = 0, RUN = 1, DRAIN = 2, DONE = 3, ERROR = 4 };

// Ring entry word 1 carries LBA bits 47:32; the upper half must be zero.
bool entry_lba_valid(const uint32_t* w) { return (w[1] & 0xFFFF0000u) == 0; }
uint64_t entry_lba(const uint32_t* w) { return w[0] | (static_cast<uint64_t>(w[1] & 0xFFFF) << 32); }

struct FileRec {
    uint32_t index = 0;
    uint64_t size = 0;
    uint64_t next_off = 0;
    uint32_t outstanding = 0;
    bool     closed = false;
    bool     counted = false;
};

struct Chunk {
    size_t   file;
    uint64_t file_off;
    uint64_t lba;
    uint32_t lbas;
    uint64_t seq;
};

struct PendingWrite {
    uint64_t start;
    uint64_t end;
    uint64_t done_at;
    uint32_t drive;
};

struct StreamModel {
    // registers
    uint64_t in_tail = 0, in_head = 0, out_tail = 0, out_head = 0;
    uint64_t in_files = 0, in_bytes = 0;
    uint32_t err_info = 0;
    bool in_done = false, out_done = false, need_space = false, err = false;
    uint32_t latch_out = 0, latch_in = 0;
    // input side
    uint64_t parsed = 0;
    bool last_seen = false;
    std::deque<std::pair<uint64_t, uint32_t>> window;
    std::vector<FileRec> files;
    std::vector<Chunk> chunks;
    uint64_t sum = 0, xr = 0;
    uint64_t reads = 0;
    // output side
    uint64_t fill = 0, total = 0;
    uint32_t seed = 0;
    uint64_t cur_lba = 0, cur_left = 0;
    uint64_t issued_lbas = 0;
    std::vector<PendingWrite> writes;
    uint64_t writes_issued = 0;
    std::array<uint8_t, RECORD_BYTES> record {};

    uint32_t status_word() const
    {
        return (in_done ? 1u : 0u) | (out_done ? 2u : 0u) | (need_space ? 4u : 0u) | (err ? 8u : 0u);
    }
    uint64_t out_bytes() const
    {
        uint64_t b = issued_lbas * LBA_BYTES;
        for (const auto& w : writes)
            b = std::min(b, w.start);
        return std::min(b, total);
    }
};

class Model final : public FileShellModel {
public:
    Model(BlockDevice& dev, FileShellModelOptions o) : dev_(dev), o_(o), rng_(o.seed)
    {
        for (auto& r : in_ring_)
            r.assign((size_t{1} << o_.log2_in_ring) * ENTRY_WORDS, 0);
        for (auto& r : out_ring_)
            r.assign((size_t{1} << o_.log2_out_ring) * ENTRY_WORDS, 0);
        args_.assign((M_ARGS_HI - M_ARGS_LO) / 4, 0);
    }

    uint32_t injected_err_info() const override { return injected_; }
    uint32_t injected_stream_mask() const override { return injected_mask_; }
    uint64_t polls() const override { return polls_; }

    uint32_t read32(uint64_t off) override
    {
        if (off == M_STATUS) {
            if (drain_left_ > 0 && --drain_left_ > 0)
                return 1u | (static_cast<uint32_t>(State::DRAIN) << 8);
            if (drain_left_ == 0 && draining_) {
                draining_ = false;
                clear();
            }
            if (state_ == State::RUN)
                step();
            bool ns = false;
            for (uint32_t s = 0; s < NSTREAMS; ++s)
                ns = ns || (stream_enabled(s) && st_[s].need_space);
            return (state_ == State::RUN ? 1u : 0u) | (state_ == State::DONE ? 2u : 0u) |
                   (state_ == State::ERROR ? 4u : 0u) | (ns && state_ == State::RUN ? 8u : 0u) |
                   (static_cast<uint32_t>(state_) << 8);
        }
        switch (off) {
        case M_CTRL: return 0;
        case M_MASK: return mask_;
        case M_VERSION: return 1;
        case M_DEPTHS: return o_.log2_in_ring | (o_.log2_out_ring << 8);
        case M_KERNEL: return 1;
        case M_STRIPE: return stripe_;
        default: break;
        }
        if (off >= M_STREAM_LO && off < M_STREAM_HI) {
            auto& s = st_[(off - M_STREAM_LO) / M_STREAM_STRIDE];
            switch ((off - M_STREAM_LO) % M_STREAM_STRIDE) {
            case 0x00: return static_cast<uint32_t>(s.in_files);
            case 0x08: return static_cast<uint32_t>(s.in_tail);
            case 0x0C: return static_cast<uint32_t>(s.in_head);
            case 0x10: return static_cast<uint32_t>(s.out_tail);
            case 0x14: return static_cast<uint32_t>(s.out_head);
            case 0x18: {
                const uint64_t v = s.out_bytes();
                s.latch_out = static_cast<uint32_t>(v >> 32);
                return static_cast<uint32_t>(v);
            }
            case 0x1C: return s.latch_out;
            case 0x20: return s.status_word();
            case 0x24: return s.err_info;
            case 0x28:
                s.latch_in = static_cast<uint32_t>(s.in_bytes >> 32);
                return static_cast<uint32_t>(s.in_bytes);
            case 0x2C: return s.latch_in;
            default: return 0;
            }
        }
        if (off >= M_ARGS_LO && off < M_ARGS_HI)
            return args_[(off - M_ARGS_LO) / 4];
        return 0;
    }

    void write32(uint64_t off, uint32_t v) override
    {
        if (off == M_CTRL) {
            if (draining_)
                return;
            if ((v & 4) && state_ == State::RUN) {
                draining_   = true;
                drain_left_ = DRAIN_STATUS_READS;
                return;
            }
            if (v & 4)
                clear();
            if ((v & 2) && state_ == State::RUN) {
                for (uint32_t s = 0; s < NSTREAMS; ++s)
                    if (stream_enabled(s))
                        set_err(st_[s], SRC_ABORT << 8);
                state_ = State::ERROR;
            }
            if ((v & 1) && state_ == State::IDLE)
                start();
            return;
        }
        if (off == M_MASK) {
            if (!busy())
                mask_ = v & 0xFF;
            return;
        }
        if (off == M_STRIPE) {
            if (!busy())
                stripe_ = v;
            return;
        }
        if (off >= M_STREAM_LO && off < M_STREAM_HI) {
            auto& s = st_[(off - M_STREAM_LO) / M_STREAM_STRIDE];
            const uint64_t reg = (off - M_STREAM_LO) % M_STREAM_STRIDE;
            if (reg == 0x08)
                s.in_tail = v;
            else if (reg == 0x10)
                s.out_tail = v;
            return;
        }
        if (off >= M_ARGS_LO && off < M_ARGS_HI) {
            args_[(off - M_ARGS_LO) / 4] = v;
            return;
        }
        if (off >= M_OUT_LO && off < M_OUT_HI) {
            const uint64_t rel = off - M_OUT_LO;
            const uint64_t s = rel / M_OUT_STRIDE, word = (rel % M_OUT_STRIDE) / 4;
            if (word < out_ring_[s].size())
                out_ring_[s][word] = v;
            return;
        }
        if (off >= M_IN_LO && off < M_IN_HI) {
            const uint64_t rel = off - M_IN_LO;
            const uint64_t s = rel / M_IN_STRIDE, word = (rel % M_IN_STRIDE) / 4;
            if (word < in_ring_[s].size())
                in_ring_[s][word] = v;
        }
    }

private:
    bool busy() const { return state_ == State::RUN || draining_; }

    void clear()
    {
        for (auto& s : st_)
            s = StreamModel {};
        state_ = State::IDLE;
        injected_ = 0;
        injected_mask_ = 0;
    }

    static uint32_t format_info(bool input, uint64_t index)
    {
        return (SRC_FORMAT << 8) | (input ? 4u : 0u) | (static_cast<uint32_t>(index & 0xFFFF) << 16);
    }

    void start()
    {
        log2_drives_ = stripe_ & 0xF;
        log2_chunk_  = (stripe_ >> 8) & 0xF;
        const bool stripe_ok =
            log2_chunk_ >= MIN_LOG2_CHUNK && log2_chunk_ <= MAX_LOG2_CHUNK && log2_drives_ <= MAX_LOG2_DRIVES;
        state_ = State::RUN;
        for (uint32_t i = 0; i < NSTREAMS; ++i) {
            if (!stream_enabled(i))
                continue;
            auto& s = st_[i];
            const uint32_t* a = &args_[i * M_ARGS_STRIDE / 4];
            s.fill  = a[0] | (static_cast<uint64_t>(a[1]) << 32);
            s.seed  = a[2];
            s.total = s.fill + RECORD_BYTES;
            if (!stripe_ok || s.fill % 64 != 0)
                set_err(s, format_info(false, 0));
        }
        if (std::any_of(st_.begin(), st_.end(), [](const StreamModel& s) { return s.err; }))
            state_ = State::ERROR;
    }

    void set_err(StreamModel& s, uint32_t info)
    {
        if (!s.err)
            s.err_info = info;
        s.err = true;
    }

    bool stream_enabled(uint32_t s) const { return mask_ >> s & 1; }

    void fail_streams(uint32_t mask, uint32_t info)
    {
        injected_      = info;
        injected_mask_ = mask;
        for (uint32_t j = 0; j < NSTREAMS; ++j)
            if (mask >> j & 1)
                set_err(st_[j], info);
        state_ = State::ERROR;
    }

    uint32_t drive_of(uint64_t lba) const
    {
        return static_cast<uint32_t>((lba >> log2_chunk_) & ((1u << log2_drives_) - 1));
    }

    // Out of range is rejected before a drive or a command identifier is involved.
    uint32_t nvme_info(bool read, uint64_t lba)
    {
        const uint32_t code = o_.fail_op_stat & 3;
        const uint32_t cid  = code == 2 ? 0 : static_cast<uint32_t>(rng_() & 0xFFFF);
        const uint32_t drv  = code == 2 ? 0 : drive_of(lba);
        return code | (read ? 4u : 0u) | (drv << 4) | (SRC_NVME << 8) | (cid << 16);
    }

    bool parse_inputs(uint32_t idx)
    {
        auto& s = st_[idx];
        const uint64_t depth = uint64_t {1} << o_.log2_in_ring;
        const uint64_t chunk = uint64_t {1} << log2_chunk_;
        while (!s.last_seen && s.parsed < s.in_tail && s.window.size() < o_.in_window) {
            const uint32_t* w = &in_ring_[idx][(s.parsed % depth) * ENTRY_WORDS];
            const uint32_t type = w[3] & 3;
            const bool     last = (w[3] >> 31) != 0;
            const uint64_t entry_no = s.parsed + 1;
            auto bad = [&] {
                set_err(s, format_info(true, entry_no));
                return false;
            };
            if ((w[3] & RESERVED_W3) || type > 1)
                return bad();
            uint32_t pieces = 0;
            if (type == 1) {
                const uint64_t size = w[0] | (static_cast<uint64_t>(w[1]) << 32);
                if (size >> 48)
                    return bad();
                if (!s.files.empty() && s.files.back().next_off < s.files.back().size)
                    return bad();
                if (last && size != 0)
                    return bad();
                if (!s.files.empty())
                    s.files.back().closed = true;
                FileRec f;
                f.index = w[2];
                f.size  = size;
                s.files.push_back(f);
            } else {
                if (s.files.empty() || w[2] == 0 || !entry_lba_valid(w))
                    return bad();
                uint64_t lba  = entry_lba(w);
                uint64_t left = w[2];
                auto& f = s.files.back();
                if (last && f.next_off + left * LBA_BYTES < f.size)
                    return bad();
                while (left > 0) {
                    const uint64_t n = std::min({left, chunk - lba % chunk, uint64_t {MAX_CHUNK_LBAS}});
                    s.chunks.push_back({s.files.size() - 1, f.next_off, lba, static_cast<uint32_t>(n), s.parsed});
                    f.next_off += n * LBA_BYTES;
                    ++f.outstanding;
                    ++pieces;
                    lba += n;
                    left -= n;
                }
            }
            s.window.emplace_back(s.parsed, pieces);
            if (last) {
                s.last_seen = true;
                s.files.back().closed = true;
            }
            ++s.parsed;
        }
        return true;
    }

    bool deliver(uint32_t idx, uint32_t ops)
    {
        auto& s = st_[idx];
        std::vector<uint8_t> buf;
        for (uint32_t k = 0; k < ops && !s.chunks.empty(); ++k) {
            const size_t pick = rng_() % s.chunks.size();
            const Chunk c = s.chunks[pick];
            s.chunks[pick] = s.chunks.back();
            s.chunks.pop_back();
            ++s.reads;
            if (o_.fail_read && o_.fail_stream == static_cast<int>(idx) && s.reads == o_.fail_op) {
                // Data lost (code 3) leaves no stream's data trustworthy; other codes belong to the rejected read.
                fail_streams((o_.fail_op_stat & 3) == 3 ? mask_ : 1u << idx, nvme_info(true, c.lba));
                return false;
            }
            buf.resize(static_cast<size_t>(c.lbas) * LBA_BYTES);
            dev_.read(c.lba * LBA_BYTES, buf);
            auto& f = s.files[c.file];
            for (uint64_t i = 0; i < buf.size(); i += 8) {
                const uint64_t o = c.file_off + i;
                if (o >= f.size)
                    break;
                uint64_t w = fmt::get64(&buf[i]);
                if (f.size - o < 8)
                    w &= (uint64_t {1} << (8 * (f.size - o))) - 1;
                const uint64_t v = w ^ o ^ (static_cast<uint64_t>(f.index) << 40);
                s.sum += v;
                s.xr ^= v;
            }
            if (c.file_off < f.size)
                s.in_bytes += std::min<uint64_t>(f.size - c.file_off, buf.size());
            --f.outstanding;
            auto& slot = s.window[c.seq - s.window.front().first];
            --slot.second;
        }
        while (!s.window.empty() && s.window.front().second == 0) {
            s.window.pop_front();
            ++s.in_head;
        }
        for (auto& f : s.files)
            if (f.closed && f.outstanding == 0 && !f.counted) {
                f.counted = true;
                ++s.in_files;
            }
        if (s.last_seen && s.chunks.empty() && s.window.empty() && !s.in_done) {
            s.in_done = true;
            uint64_t in_total = 0;
            for (const auto& f : s.files)
                in_total += f.size;
            fmt::put64(&s.record[0], in_total);
            fmt::put64(&s.record[8], s.sum);
            fmt::put64(&s.record[16], s.xr);
            fmt::put32(&s.record[24], static_cast<uint32_t>(s.files.size()));
            fmt::put32(&s.record[28], RECORD_MAGIC);
        }
        return true;
    }

    uint8_t out_byte(const StreamModel& s, uint64_t p) const
    {
        if (p < s.fill) {
            const uint64_t j = p / 8;
            const uint64_t w = (static_cast<uint64_t>(static_cast<uint32_t>(j) ^ s.seed) << 32) | static_cast<uint32_t>(j);
            return static_cast<uint8_t>(w >> (8 * (p % 8)));
        }
        if (p < s.total)
            return s.record[p - s.fill];
        return 0;
    }

    // False when the stream failed; the caller stops the job.
    bool emit(uint32_t idx, uint32_t ops)
    {
        auto& s = st_[idx];
        const uint64_t depth = uint64_t {1} << o_.log2_out_ring;
        const uint64_t chunk = uint64_t {1} << log2_chunk_;
        s.need_space = false;
        std::vector<uint8_t> buf;
        for (uint32_t k = 0; k < ops; ++k) {
            const uint64_t done_bytes = s.issued_lbas * LBA_BYTES;
            uint64_t ready = 0;
            if (s.in_done)
                ready = done_bytes < s.total ? div_ceil<uint64_t>(s.total - done_bytes, LBA_BYTES) : 0;
            else
                ready = done_bytes < s.fill ? (s.fill - done_bytes) / LBA_BYTES : 0;
            if (ready == 0)
                break;
            if (s.cur_left == 0) {
                if (s.out_head == s.out_tail) {
                    s.need_space = true;
                    break;
                }
                const uint32_t* w = &out_ring_[idx][(s.out_head % depth) * ENTRY_WORDS];
                if (w[3] != 0 || w[2] == 0 || !entry_lba_valid(w)) {
                    set_err(s, format_info(false, s.out_head + 1));
                    return false;
                }
                s.cur_lba  = entry_lba(w);
                s.cur_left = w[2];
                ++s.out_head;
            }
            const uint64_t n = std::min({s.cur_left, ready, chunk - s.cur_lba % chunk, uint64_t {MAX_CHUNK_LBAS}});
            ++s.writes_issued;
            if (!o_.fail_read && o_.fail_stream == static_cast<int>(idx) && s.writes_issued == o_.fail_op) {
                // A write completion carries no stream: every stream with writes in flight on that drive fails.
                const uint32_t code = o_.fail_op_stat & 3;
                const uint32_t drv  = drive_of(s.cur_lba);
                uint32_t mask = 1u << idx;
                for (uint32_t j = 0; j < NSTREAMS; ++j)
                    if (stream_enabled(j))
                        for (const auto& pw : st_[j].writes)
                            if (code == 2 || pw.drive == drv)
                                mask |= 1u << j;
                fail_streams(mask, nvme_info(false, s.cur_lba));
                return false;
            }
            buf.resize(n * LBA_BYTES);
            for (uint64_t i = 0; i < buf.size(); ++i)
                buf[i] = out_byte(s, done_bytes + i);
            dev_.write(s.cur_lba * LBA_BYTES, buf);
            s.writes.push_back({done_bytes, done_bytes + buf.size(), polls_ + rng_() % 3, drive_of(s.cur_lba)});
            s.cur_lba += n;
            s.cur_left -= n;
            s.issued_lbas += n;
        }
        return true;
    }

    void step()
    {
        ++polls_;
        for (uint32_t i = 0; i < NSTREAMS; ++i) {
            auto& s = st_[i];
            std::erase_if(s.writes, [&](const PendingWrite& w) { return w.done_at < polls_; });
        }
        if (o_.fail_hbm_poll != 0 && polls_ == o_.fail_hbm_poll) {
            // The ring port serves every stream, so a bad HBM response leaves none of them consistent.
            fail_streams(mask_, SRC_HBM << 8);
            return;
        }
        for (uint32_t i = 0; i < NSTREAMS && state_ == State::RUN; ++i) {
            if (!stream_enabled(i))
                continue;
            auto& s = st_[i];
            const uint32_t ops = 1 + static_cast<uint32_t>(rng_() % o_.max_ops_per_poll);
            if (!parse_inputs(i) || !deliver(i, ops) || !emit(i, ops)) {
                state_ = State::ERROR;
                break;
            }
            s.out_done = s.in_done && s.issued_lbas * LBA_BYTES >= s.total && s.writes.empty();
        }
        if (state_ != State::RUN)
            return;
        bool all = true;
        for (uint32_t i = 0; i < NSTREAMS; ++i)
            if (stream_enabled(i))
                all = all && st_[i].in_done && st_[i].out_done;
        if (all)
            state_ = State::DONE;
    }

    BlockDevice&                            dev_;
    FileShellModelOptions                   o_;
    std::mt19937_64                         rng_;
    std::array<StreamModel, NSTREAMS>       st_ {};
    std::array<std::vector<uint32_t>, NSTREAMS> in_ring_;
    std::array<std::vector<uint32_t>, NSTREAMS> out_ring_;
    std::vector<uint32_t>                   args_;
    uint32_t                                mask_     = 0;
    uint32_t                                stripe_   = 0;
    bool                                    draining_    = false;
    uint32_t                                drain_left_  = 0;
    State                                   state_    = State::IDLE;
    uint32_t                                injected_ = 0;
    uint32_t                                injected_mask_ = 0;
    uint32_t                                log2_drives_ = 0;
    uint32_t                                log2_chunk_  = 0;
    uint64_t                                polls_    = 0;
};

} // namespace

std::unique_ptr<FileShellModel> make_file_shell_model(BlockDevice& dev, FileShellModelOptions opts)
{
    return std::make_unique<Model>(dev, opts);
}

} // namespace iuv_exfat
