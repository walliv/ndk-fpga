// volume.cpp: exFAT volume metadata owner (allocation, entry sets, group commit, recovery)
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#include "iuv_exfat/volume.hpp"

#include <algorithm>
#include <array>
#include <cstring>
#include <deque>
#include <functional>
#include <map>
#include <optional>
#include <set>
#include <stdexcept>
#include <system_error>
#include <unordered_map>

#include "error.hpp"
#include "exfat_format.hpp"

namespace iuv_exfat {

namespace {

using namespace fmt;

[[noreturn]] void corrupt(const std::string& msg)
{
    fail(std::errc::io_error, "corrupt volume: " + msg);
}

struct Run {
    uint32_t start;
    uint32_t len;

    uint32_t end() const { return start + len; }
    uint32_t last() const { return start + len - 1; }
};

// Adds a run, joining it to the previous one when the clusters are adjacent.
void append_run(std::vector<Run>& runs, const Run& r)
{
    if (!runs.empty() && runs.back().end() == r.start)
        runs.back().len += r.len;
    else
        runs.push_back(r);
}

bool bit_test(std::span<const uint8_t> bits, uint32_t i) { return (bits[i >> 3] >> (i & 7)) & 1; }

void bit_assign(std::span<uint8_t> bits, uint32_t i, bool v)
{
    const auto m = static_cast<uint8_t>(1u << (i & 7));
    if (v)
        bits[i >> 3] |= m;
    else
        bits[i >> 3] &= static_cast<uint8_t>(~m);
}

void put_timestamp(uint8_t* e, uint32_t ts_off, uint32_t ms10_off, uint32_t utc_off, const Timestamp& ts)
{
    put32(e + ts_off, ts.stamp);
    e[ms10_off] = ts.ms10;
    e[utc_off]  = ts.utc;
}

void put_access(uint8_t* e, const Timestamp& ts)
{
    put32(e + FILE_ACCESS_TS, ts.stamp);
    e[FILE_ACCESS_UTC] = ts.utc;
}

// Cluster allocation described by a directory entry.
struct Alloc {
    uint32_t first  = 0;
    uint64_t bytes  = 0;
    bool     no_fat = false;
};

struct Node {
    Node*          parent  = nullptr;
    bool           is_root = false;
    bool           is_dir  = false;
    std::u16string name;
    std::u16string key;
    uint32_t       set_index = 0;
    uint32_t       set_count = 0;
    uint16_t       attributes = 0;
    uint8_t        flags      = 0;
    uint64_t       valid_size = 0;
    uint64_t       size       = 0;
    uint32_t       first_cluster = 0;
    uint32_t       access_ts     = 0;
    std::vector<Alloc> extra_allocs;
    bool               runs_known = false;
    std::vector<Run>   runs;
    std::vector<uint8_t> data;
    uint32_t             free_hint = 0;
    std::unordered_map<std::u16string, std::unique_ptr<Node>> children;
    uint64_t output = 0;
    bool     busy   = false;

    Alloc alloc() const { return {first_cluster, size, (flags & FLAG_NO_FAT_CHAIN) != 0}; }
    bool unfinished() const { return !is_dir && access_ts == 0 && valid_size == 0; }
    uint32_t entry_count() const { return static_cast<uint32_t>(data.size() / ENTRY_BYTES); }
    uint8_t* entry(size_t i) { return data.data() + i * ENTRY_BYTES; }
    const uint8_t* entry(size_t i) const { return data.data() + i * ENTRY_BYTES; }
};

// Reads the fields an entry set carries; a set without the allocation bit owns no clusters.
void unpack_set(Node& n, const uint8_t* e)
{
    const uint8_t* s = e + ENTRY_BYTES;
    n.attributes    = get16(e + FILE_ATTRIBUTES);
    n.is_dir        = (n.attributes & ATTR_DIRECTORY) != 0;
    n.access_ts     = get32(e + FILE_ACCESS_TS);
    n.flags         = s[SEC_FLAGS];
    n.valid_size    = get64(s + STREAM_VALID_LEN);
    n.size          = get64(s + SEC_DATA_LENGTH);
    n.first_cluster = get32(s + SEC_FIRST_CLUSTER);
    if (!(n.flags & FLAG_ALLOC_POSSIBLE)) {
        n.first_cluster = 0;
        n.size          = 0;
    }
}

constexpr uint32_t FAT_PAGE_ENTRIES = 1024;

class VolumeImpl final : public Volume {
public:
    VolumeImpl(std::unique_ptr<BlockDevice> dev, VolumeOptions opts)
        : dev_(std::move(dev)), opts_(opts)
    {
    }

    ~VolumeImpl() override
    {
        try {
            close();
        } catch (...) {
        }
    }

    void load();

    BlockDevice& device() override { return *dev_; }
    VolumeOptions options() const override { return opts_; }
    VolumeInfo info() const override;
    bool dirty() const override { return dirty_on_disk_; }
    bool reservations_flushed() const override { return !unflushed_; }

    std::vector<DirEntryInfo> list(const std::string& path) override;
    DirEntryInfo stat(const std::string& path) override;
    bool exists(const std::string& path) override;
    FileExtents extents(const std::string& path) override;

    void make_directory(const std::string& path) override;
    void remove(const std::string& path) override;

    Output reserve(const std::string& path, uint64_t nbytes) override;
    std::vector<Extent> extend(Output& output, uint64_t nbytes) override;
    void finalize(Output& output, uint64_t nbytes) override;
    void abandon(Output& output) override;
    Output adopt(const std::string& path) override;
    void commit() override;
    void flush() override;
    RecoverReport recover() override;
    CheckReport check() override;
    void close() override;

private:
    enum class StagedKind { FINALIZE, ABANDON, REMOVE };
    struct Staged {
        StagedKind kind;
        Node*      node;
        uint64_t   handle;
        uint64_t   nbytes;
        Timestamp  ts;
    };
    struct OutputState {
        Node*            node   = nullptr;
        std::vector<Run> runs;
        bool             staged = false;
    };

    // geometry
    uint64_t heap_offset() const { return part_off_ + (static_cast<uint64_t>(heap_off_sec_) << SECTOR_SHIFT); }
    uint64_t fat_offset() const { return part_off_ + static_cast<uint64_t>(fat_off_sec_) * SECTOR_BYTES; }
    uint64_t cluster_off(uint32_t c) const { return heap_offset() + (static_cast<uint64_t>(c - FIRST_CLUSTER) << cluster_shift_); }
    bool valid_cluster(uint32_t c) const { return c >= FIRST_CLUSTER && c < cluster_count_ + FIRST_CLUSTER; }
    uint64_t clusters_for(uint64_t bytes) const { return (bytes + cluster_bytes_ - 1) >> cluster_shift_; }

    // FAT
    uint32_t fat_get(uint32_t c);
    void fat_set(uint32_t c, uint32_t v);
    void fat_free(const Run& r);
    void fat_write_dirty();
    void write_chain(const std::vector<Run>& runs);

    // bitmap
    bool bit_get(uint32_t c) const { return bit_test(bitmap_, c - FIRST_CLUSTER); }
    void bits_set(const Run& r, bool v);
    void bitmap_write_dirty();

    // free run index
    void free_insert(Run r);
    void free_take(uint32_t start, uint32_t n);
    std::vector<Run> allocate(uint64_t n);
    void build_free_index();

    // runs and data
    std::vector<Run> alloc_runs(const Alloc& a);
    std::vector<Run> root_runs();
    const std::vector<Run>& node_runs(Node* n);
    std::vector<uint8_t> read_runs(const std::vector<Run>& runs, uint64_t bytes);
    void write_runs(const std::vector<Run>& runs, uint64_t off, std::span<const uint8_t> data);
    std::vector<Extent> runs_to_extents(const std::vector<Run>& runs, uint64_t lbas_limit) const;

    // directories
    void parse_dir(Node* dir);
    void parse_set(Node* dir, uint32_t index);
    void load_tree();
    std::optional<uint32_t> find_slots(Node* dir, uint32_t count);
    uint32_t claim_slots(Node* dir, uint32_t count);
    void grow_dir(Node* dir);
    void dir_write(Node* dir, uint32_t index, uint32_t count);
    uint8_t* set_ptr(Node* n) { return n->parent->entry(n->set_index); }
    void update_stream(Node* n);
    void delete_set(Node* n);
    Node* insert_set(Node* dir, const std::u16string& name, const std::vector<uint8_t>& set, uint32_t slot);
    std::vector<uint8_t> build_set(const std::u16string& name, uint16_t attr, uint8_t flags, uint32_t first, uint64_t size,
                                   uint64_t valid, const Timestamp& ts, bool tag_unfinished) const;
    void zero_cluster(uint32_t c);

    // lookup
    Node* lookup(const std::string& path);
    std::pair<Node*, std::u16string> resolve_parent(const std::string& path);
    DirEntryInfo describe(const Node* n) const;
    static void for_each_node(Node* dir, const std::function<void(Node*)>& fn);

    // state
    void ensure_writable() const;
    void ensure_open_writable() const;
    Output make_output(Node* n, const std::string& path, const std::vector<Run>& runs) const;
    void ensure_dirty();
    void write_boot_flags(bool dirty);
    void maybe_clear_dirty();
    OutputState& output_state(const Output& out);
    std::vector<uint8_t> owner_bits(uint64_t& cross);

    std::unique_ptr<BlockDevice> dev_;
    VolumeOptions                opts_;
    uint64_t                     part_off_      = 0;
    std::array<uint8_t, SECTOR_BYTES> boot_ {};
    uint32_t                     fat_off_sec_   = 0;
    uint32_t                     fat_len_sec_   = 0;
    uint32_t                     heap_off_sec_  = 0;
    uint32_t                     cluster_count_ = 0;
    uint32_t                     root_cluster_  = 0;
    uint32_t                     cluster_shift_ = 0;
    uint32_t                     cluster_bytes_ = 0;
    UpcaseTable                  upcase_;
    Alloc                        bitmap_alloc_;
    Alloc                        upcase_alloc_;
    std::vector<Run>             bitmap_runs_;
    std::vector<Run>             upcase_runs_;
    std::vector<uint8_t>         bitmap_;
    std::vector<std::pair<uint64_t, uint64_t>> bitmap_dirty_;
    std::unordered_map<uint32_t, std::vector<uint32_t>> fat_pages_;
    std::vector<uint32_t>        fat_dirty_;
    std::unique_ptr<Node>        root_;
    std::map<uint32_t, uint32_t> free_by_start_;
    std::set<std::pair<uint32_t, uint32_t>> free_by_len_;
    uint64_t                     free_count_ = 0;
    std::unordered_map<uint64_t, OutputState> outputs_;
    uint64_t                     next_handle_ = 1;
    std::vector<Staged>          staged_;
    std::vector<uint8_t>         zero_cluster_buf_;
    bool                         dirty_on_disk_ = false;
    bool                         needs_recover_ = false;
    uint64_t                     orphan_unfinished_ = 0;
    bool                         unflushed_     = false;
    bool                         closed_        = false;
};

// ---------------------------------------------------------------- FAT

uint32_t VolumeImpl::fat_get(uint32_t c)
{
    const uint32_t page = c / FAT_PAGE_ENTRIES;
    auto it = fat_pages_.find(page);
    if (it == fat_pages_.end()) {
        const uint64_t fat_bytes = static_cast<uint64_t>(fat_len_sec_) * SECTOR_BYTES;
        const uint64_t lo = static_cast<uint64_t>(page) * FAT_PAGE_ENTRIES * FAT_ENTRY_BYTES;
        if (lo >= fat_bytes)
            corrupt("FAT index beyond the FAT");
        const uint64_t len = std::min<uint64_t>(FAT_PAGE_ENTRIES * FAT_ENTRY_BYTES, fat_bytes - lo);
        std::vector<uint8_t> raw(FAT_PAGE_ENTRIES * FAT_ENTRY_BYTES, 0);
        dev_->read(fat_offset() + lo, std::span(raw.data(), len));
        std::vector<uint32_t> entries(FAT_PAGE_ENTRIES);
        for (uint32_t i = 0; i < FAT_PAGE_ENTRIES; ++i)
            entries[i] = get32(&raw[i * FAT_ENTRY_BYTES]);
        it = fat_pages_.emplace(page, std::move(entries)).first;
    }
    return it->second[c % FAT_PAGE_ENTRIES];
}

void VolumeImpl::fat_set(uint32_t c, uint32_t v)
{
    if (!valid_cluster(c))
        throw std::logic_error("FAT write to an invalid cluster");
    fat_get(c);
    fat_pages_[c / FAT_PAGE_ENTRIES][c % FAT_PAGE_ENTRIES] = v;
    fat_dirty_.push_back(c);
}

void VolumeImpl::fat_free(const Run& r)
{
    for (uint32_t c = r.start; c < r.end(); ++c)
        fat_set(c, 0);
}

void VolumeImpl::fat_write_dirty()
{
    if (fat_dirty_.empty())
        return;
    std::sort(fat_dirty_.begin(), fat_dirty_.end());
    fat_dirty_.erase(std::unique(fat_dirty_.begin(), fat_dirty_.end()), fat_dirty_.end());
    const uint64_t base = fat_offset();
    std::vector<uint8_t> buf;
    size_t i = 0;
    while (i < fat_dirty_.size()) {
        size_t j = i + 1;
        while (j < fat_dirty_.size() && fat_dirty_[j] == fat_dirty_[j - 1] + 1 && j - i < (1u << 20))
            ++j;
        buf.resize((j - i) * FAT_ENTRY_BYTES);
        for (size_t k = i; k < j; ++k)
            put32(&buf[(k - i) * FAT_ENTRY_BYTES], fat_get(fat_dirty_[k]));
        dev_->write(base + static_cast<uint64_t>(fat_dirty_[i]) * FAT_ENTRY_BYTES, buf);
        i = j;
    }
    fat_dirty_.clear();
}

void VolumeImpl::write_chain(const std::vector<Run>& runs)
{
    for (size_t r = 0; r < runs.size(); ++r) {
        const uint32_t end = runs[r].last();
        for (uint32_t c = runs[r].start; c < end; ++c)
            fat_set(c, c + 1);
        fat_set(end, r + 1 < runs.size() ? runs[r + 1].start : FAT_EOC);
    }
}

// ---------------------------------------------------------------- bitmap

void VolumeImpl::bits_set(const Run& r, bool v)
{
    for (uint32_t c = r.start; c < r.end(); ++c)
        bit_assign(bitmap_, c - FIRST_CLUSTER, v);
    const uint64_t lo = (r.start - FIRST_CLUSTER) >> 3;
    const uint64_t hi = ((r.last() - FIRST_CLUSTER) >> 3) + 1;
    bitmap_dirty_.emplace_back(lo, hi);
}

void VolumeImpl::bitmap_write_dirty()
{
    if (bitmap_dirty_.empty())
        return;
    std::sort(bitmap_dirty_.begin(), bitmap_dirty_.end());
    uint64_t lo = bitmap_dirty_[0].first;
    uint64_t hi = bitmap_dirty_[0].second;
    for (size_t i = 1; i <= bitmap_dirty_.size(); ++i) {
        if (i < bitmap_dirty_.size() && bitmap_dirty_[i].first <= hi) {
            hi = std::max(hi, bitmap_dirty_[i].second);
            continue;
        }
        write_runs(bitmap_runs_, lo, std::span<const uint8_t>(bitmap_.data() + lo, hi - lo));
        if (i < bitmap_dirty_.size()) {
            lo = bitmap_dirty_[i].first;
            hi = bitmap_dirty_[i].second;
        }
    }
    bitmap_dirty_.clear();
}

// ---------------------------------------------------------------- free run index

void VolumeImpl::free_insert(Run r)
{
    free_count_ += r.len;
    auto next = free_by_start_.lower_bound(r.start);
    if (next != free_by_start_.begin()) {
        auto prev = std::prev(next);
        if (prev->first + prev->second == r.start) {
            r.start = prev->first;
            r.len += prev->second;
            free_by_len_.erase({prev->second, prev->first});
            free_by_start_.erase(prev);
        }
    }
    if (next != free_by_start_.end() && r.end() == next->first) {
        r.len += next->second;
        free_by_len_.erase({next->second, next->first});
        free_by_start_.erase(next);
    }
    free_by_start_.emplace(r.start, r.len);
    free_by_len_.emplace(r.len, r.start);
}

void VolumeImpl::free_take(uint32_t start, uint32_t n)
{
    auto it = free_by_start_.upper_bound(start);
    if (it == free_by_start_.begin())
        throw std::logic_error("taking a cluster that is not free");
    --it;
    const uint32_t rs = it->first;
    const uint32_t rl = it->second;
    if (start + n > rs + rl)
        throw std::logic_error("taking clusters that are not free");
    free_by_len_.erase({rl, rs});
    free_by_start_.erase(it);
    if (start > rs) {
        free_by_start_.emplace(rs, start - rs);
        free_by_len_.emplace(start - rs, rs);
    }
    if (start + n < rs + rl) {
        free_by_start_.emplace(start + n, rs + rl - start - n);
        free_by_len_.emplace(rs + rl - start - n, start + n);
    }
    free_count_ -= n;
}

// Best-fitting single run first, else largest runs and a best-fitting remainder: fewest runs.
std::vector<Run> VolumeImpl::allocate(uint64_t n)
{
    if (n > free_count_)
        fail(std::errc::no_space_on_device, "not enough free clusters");
    std::vector<Run> out;
    uint64_t rem = n;
    while (rem > 0) {
        auto fit = free_by_len_.lower_bound({static_cast<uint32_t>(std::min<uint64_t>(rem, UINT32_MAX)), 0});
        if (fit != free_by_len_.end() && rem <= UINT32_MAX) {
            const Run r {fit->second, static_cast<uint32_t>(rem)};
            free_take(r.start, r.len);
            out.push_back(r);
            break;
        }
        auto largest = std::prev(free_by_len_.end());
        const Run r {largest->second, largest->first};
        free_take(r.start, r.len);
        out.push_back(r);
        rem -= r.len;
    }
    std::sort(out.begin(), out.end(), [](const Run& a, const Run& b) { return a.start < b.start; });
    return out;
}

void VolumeImpl::build_free_index()
{
    free_by_start_.clear();
    free_by_len_.clear();
    free_count_ = 0;
    uint32_t c = FIRST_CLUSTER;
    const uint32_t end = cluster_count_ + FIRST_CLUSTER;
    while (c < end) {
        const uint32_t i = c - FIRST_CLUSTER;
        if ((i & 7) == 0 && bitmap_[i >> 3] == 0xFF && c + 8 <= end) {
            c += 8;
            continue;
        }
        if (bit_get(c)) {
            ++c;
            continue;
        }
        const uint32_t s = c;
        while (c < end && !bit_get(c))
            ++c;
        free_insert({s, c - s});
    }
}

// ---------------------------------------------------------------- runs and data

std::vector<Run> VolumeImpl::alloc_runs(const Alloc& a)
{
    std::vector<Run> runs;
    const uint64_t n = clusters_for(a.bytes);
    if (n == 0 || a.first == 0)
        return runs;
    if (n > cluster_count_)
        corrupt("allocation longer than the volume");
    if (a.no_fat) {
        if (!valid_cluster(a.first) || !valid_cluster(static_cast<uint32_t>(a.first + n - 1)))
            corrupt("contiguous allocation outside the cluster heap");
        runs.push_back({a.first, static_cast<uint32_t>(n)});
        return runs;
    }
    uint32_t c = a.first;
    for (uint64_t i = 0; i < n; ++i) {
        if (!valid_cluster(c))
            corrupt("FAT chain reaches an invalid cluster");
        append_run(runs, {c, 1});
        const uint32_t next = fat_get(c);
        if (i + 1 < n)
            c = next;
    }
    return runs;
}

std::vector<Run> VolumeImpl::root_runs()
{
    std::vector<Run> runs;
    uint32_t c = root_cluster_;
    for (uint32_t i = 0; c != FAT_EOC; ++i) {
        if (!valid_cluster(c) || i >= cluster_count_)
            corrupt("root directory FAT chain is broken");
        append_run(runs, {c, 1});
        c = fat_get(c);
    }
    return runs;
}

const std::vector<Run>& VolumeImpl::node_runs(Node* n)
{
    if (!n->runs_known) {
        n->runs = n->is_root ? root_runs() : alloc_runs(n->alloc());
        n->runs_known = true;
    }
    return n->runs;
}

std::vector<uint8_t> VolumeImpl::read_runs(const std::vector<Run>& runs, uint64_t bytes)
{
    std::vector<uint8_t> out(bytes);
    uint64_t pos = 0;
    for (const auto& r : runs) {
        if (pos >= bytes)
            break;
        const uint64_t len = std::min<uint64_t>(static_cast<uint64_t>(r.len) << cluster_shift_, bytes - pos);
        dev_->read(cluster_off(r.start), std::span(out.data() + pos, len));
        pos += len;
    }
    if (pos < bytes)
        corrupt("allocation shorter than its data length");
    return out;
}

void VolumeImpl::write_runs(const std::vector<Run>& runs, uint64_t off, std::span<const uint8_t> data)
{
    uint64_t run_lo = 0;
    size_t   done   = 0;
    for (const auto& r : runs) {
        const uint64_t run_hi = run_lo + (static_cast<uint64_t>(r.len) << cluster_shift_);
        const uint64_t pos    = off + done;
        if (done < data.size() && pos < run_hi) {
            const uint64_t len = std::min<uint64_t>(run_hi - pos, data.size() - done);
            dev_->write(cluster_off(r.start) + (pos - run_lo), data.subspan(done, len));
            done += len;
        }
        run_lo = run_hi;
    }
    if (done != data.size())
        throw std::logic_error("write beyond the end of an allocation");
}

// Splits stay cluster aligned so every extent starts and ends on a stripe boundary.
std::vector<Extent> VolumeImpl::runs_to_extents(const std::vector<Run>& runs, uint64_t lbas_limit) const
{
    const uint64_t spc       = static_cast<uint64_t>(cluster_bytes_) / LBA_BYTES;
    const uint64_t max_count = (UINT32_MAX / spc) * spc;
    std::vector<Extent> out;
    uint64_t left = lbas_limit;
    for (const auto& r : runs) {
        uint64_t lba   = cluster_off(r.start) / LBA_BYTES;
        uint64_t count = std::min<uint64_t>(static_cast<uint64_t>(r.len) * spc, left);
        left -= count;
        while (count > 0) {
            const uint64_t piece = std::min(count, max_count);
            out.push_back({lba, static_cast<uint32_t>(piece)});
            lba += piece;
            count -= piece;
        }
        if (left == 0)
            break;
    }
    return out;
}

// ---------------------------------------------------------------- directories

void VolumeImpl::parse_set(Node* dir, uint32_t index)
{
    const uint32_t total = dir->entry_count();
    const uint8_t* e     = dir->entry(index);
    const uint32_t sc    = e[FILE_SECONDARY_COUNT];
    const uint32_t count = sc + 1;
    if (sc < 2 || index + count > total)
        corrupt("file entry set with a bad secondary count");
    const uint8_t* s = e + ENTRY_BYTES;
    if (s[0] != TYPE_STREAM)
        corrupt("file entry not followed by a stream extension");
    const uint32_t name_len = s[STREAM_NAME_LEN];
    const uint32_t names    = name_entry_count(name_len);
    if (name_len == 0 || sc < 1 + names)
        corrupt("file entry set with a bad name length");
    if (get16(e + FILE_SET_CHECKSUM) != entry_set_checksum(std::span(e, static_cast<size_t>(count) * ENTRY_BYTES)))
        corrupt("entry set checksum mismatch");

    auto node    = std::make_unique<Node>();
    node->parent = dir;
    for (uint32_t k = 0; k < names; ++k) {
        const uint8_t* ne = e + static_cast<size_t>(2 + k) * ENTRY_BYTES;
        if (ne[0] != TYPE_NAME)
            corrupt("missing file name entry");
        for (uint32_t u = 0; u < NAME_UNITS_PER_ENTRY && node->name.size() < name_len; ++u)
            node->name.push_back(static_cast<char16_t>(get16(ne + 2 + 2 * u)));
    }
    for (uint32_t k = 2 + names; k < count; ++k) {
        const uint8_t* xe = e + static_cast<size_t>(k) * ENTRY_BYTES;
        if ((xe[0] & (TYPE_IN_USE | TYPE_SECONDARY)) != (TYPE_IN_USE | TYPE_SECONDARY))
            corrupt("entry set interrupted");
        if (!(xe[0] & TYPE_BENIGN))
            fail(std::errc::not_supported, "unknown critical secondary entry");
        if (xe[SEC_FLAGS] & FLAG_ALLOC_POSSIBLE)
            node->extra_allocs.push_back({get32(xe + SEC_FIRST_CLUSTER), get64(xe + SEC_DATA_LENGTH),
                                          (xe[SEC_FLAGS] & FLAG_NO_FAT_CHAIN) != 0});
    }
    node->key = upcase_.up(node->name);
    if (get16(s + STREAM_NAME_HASH) != name_hash(node->key))
        corrupt("name hash mismatch");
    node->set_index = index;
    node->set_count = count;
    unpack_set(*node, e);
    if (node->valid_size > node->size)
        corrupt("valid data length beyond data length");
    if (node->is_dir && (node->size % cluster_bytes_ != 0 || node->size == 0))
        corrupt("directory size is not a cluster multiple");
    auto key = node->key;
    if (!dir->children.emplace(std::move(key), std::move(node)).second)
        corrupt("duplicate name in a directory");
}

void VolumeImpl::parse_dir(Node* dir)
{
    const uint32_t total = dir->entry_count();
    bool hint_set = false;
    uint32_t i = 0;
    while (i < total) {
        const uint8_t* e = dir->entry(i);
        const uint8_t  t = e[0];
        if (!(t & TYPE_IN_USE) && !hint_set) {
            dir->free_hint = i;
            hint_set = true;
        }
        if (t == TYPE_EOD)
            break;
        if (!(t & TYPE_IN_USE)) {
            ++i;
            continue;
        }
        const uint32_t set_len = 1u + e[FILE_SECONDARY_COUNT];
        if (t == TYPE_FILE) {
            parse_set(dir, i);
            i += set_len;
            continue;
        }
        if (t & TYPE_SECONDARY)
            corrupt("secondary entry without a primary");
        if (dir->is_root && (t == TYPE_BITMAP || t == TYPE_UPCASE || t == TYPE_LABEL)) {
            ++i;
            continue;
        }
        if (t & TYPE_BENIGN) {
            i += set_len;
            continue;
        }
        fail(std::errc::not_supported, "unknown critical primary directory entry");
    }
    if (!hint_set)
        dir->free_hint = std::min(i, total);
}

void VolumeImpl::load_tree()
{
    std::deque<Node*> queue {root_.get()};
    while (!queue.empty()) {
        Node* dir = queue.front();
        queue.pop_front();
        parse_dir(dir);
        for (auto& [key, child] : dir->children) {
            if (!child->is_dir)
                continue;
            child->data = read_runs(node_runs(child.get()), child->size);
            queue.push_back(child.get());
        }
    }
}

std::optional<uint32_t> VolumeImpl::find_slots(Node* dir, uint32_t count)
{
    const uint32_t total = dir->entry_count();
    uint32_t run = 0;
    uint32_t start = 0;
    for (uint32_t i = dir->free_hint; i < total; ++i) {
        const uint8_t t = *dir->entry(i);
        if (t == TYPE_EOD) {
            const uint32_t s = run ? start : i;
            if (s + count <= total)
                return s;
            return std::nullopt;
        }
        if (t & TYPE_IN_USE) {
            run = 0;
            continue;
        }
        if (run++ == 0)
            start = i;
        if (run == count)
            return start;
    }
    return std::nullopt;
}

uint32_t VolumeImpl::claim_slots(Node* dir, uint32_t count)
{
    auto slot = find_slots(dir, count);
    while (!slot) {
        grow_dir(dir);
        slot = find_slots(dir, count);
    }
    uint32_t first_free = dir->free_hint;
    while (first_free < *slot && (*dir->entry(first_free) & TYPE_IN_USE))
        ++first_free;
    dir->free_hint = (first_free == *slot) ? *slot + count : first_free;
    return *slot;
}

void VolumeImpl::zero_cluster(uint32_t c)
{
    if (zero_cluster_buf_.size() != cluster_bytes_)
        zero_cluster_buf_.assign(cluster_bytes_, 0);
    dev_->write(cluster_off(c), zero_cluster_buf_);
}

// The new cluster is zeroed, marked and linked, then flushed before the size that exposes it changes.
void VolumeImpl::grow_dir(Node* dir)
{
    auto& runs = dir->runs;
    const uint32_t last = runs.back().last();
    uint32_t c = 0;
    auto adj = free_by_start_.find(last + 1);
    if (adj != free_by_start_.end()) {
        c = last + 1;
    } else {
        if (free_by_len_.empty())
            fail(std::errc::no_space_on_device, "no free cluster to grow a directory");
        c = free_by_len_.begin()->second;
    }
    free_take(c, 1);
    zero_cluster(c);
    bits_set({c, 1}, true);
    bitmap_write_dirty();
    const bool contiguous = c == last + 1;
    const bool was_no_fat = !dir->is_root && (dir->flags & FLAG_NO_FAT_CHAIN);
    const bool to_fat     = was_no_fat && !contiguous;
    if (to_fat) {
        auto chain = runs;
        chain.push_back({c, 1});
        write_chain(chain);
    } else if (!was_no_fat) {
        fat_set(c, FAT_EOC);
        if (!dir->is_root)
            fat_set(last, c);
    }
    fat_write_dirty();
    dev_->flush();
    if (dir->is_root) {
        fat_set(last, c);
        fat_write_dirty();
    } else {
        if (to_fat)
            dir->flags &= static_cast<uint8_t>(~FLAG_NO_FAT_CHAIN);
        dir->size += cluster_bytes_;
        dir->valid_size = dir->size;
        update_stream(dir);
        dir_write(dir->parent, dir->set_index, dir->set_count);
    }
    if (contiguous)
        ++runs.back().len;
    else
        runs.push_back({c, 1});
    dir->data.resize(dir->data.size() + cluster_bytes_, 0);
}

void VolumeImpl::dir_write(Node* dir, uint32_t index, uint32_t count)
{
    const uint64_t off = static_cast<uint64_t>(index) * ENTRY_BYTES;
    write_runs(node_runs(dir), off, std::span<const uint8_t>(dir->entry(index), static_cast<size_t>(count) * ENTRY_BYTES));
}

void VolumeImpl::update_stream(Node* n)
{
    uint8_t* e = set_ptr(n);
    uint8_t* s = e + ENTRY_BYTES;
    s[SEC_FLAGS] = n->flags;
    put64(s + STREAM_VALID_LEN, n->valid_size);
    put32(s + SEC_FIRST_CLUSTER, n->first_cluster);
    put64(s + SEC_DATA_LENGTH, n->size);
    put16(e + FILE_SET_CHECKSUM, entry_set_checksum(std::span(e, static_cast<size_t>(n->set_count) * ENTRY_BYTES)));
}

void VolumeImpl::delete_set(Node* n)
{
    Node* dir = n->parent;
    for (uint32_t k = 0; k < n->set_count; ++k)
        *dir->entry(n->set_index + k) &= static_cast<uint8_t>(~TYPE_IN_USE);
    dir_write(dir, n->set_index, n->set_count);
    dir->free_hint = std::min(dir->free_hint, n->set_index);
    const std::u16string key = n->key;
    dir->children.erase(key);
}

std::vector<uint8_t> VolumeImpl::build_set(const std::u16string& name, uint16_t attr, uint8_t flags, uint32_t first,
                                           uint64_t size, uint64_t valid, const Timestamp& ts, bool tag_unfinished) const
{
    const uint32_t names = name_entry_count(name.size());
    const uint32_t count = file_set_count(name.size());
    std::vector<uint8_t> set(static_cast<size_t>(count) * ENTRY_BYTES, 0);
    uint8_t* e = set.data();
    e[0] = TYPE_FILE;
    e[FILE_SECONDARY_COUNT] = static_cast<uint8_t>(count - 1);
    put16(e + FILE_ATTRIBUTES, attr);
    put_timestamp(e, FILE_CREATE_TS, FILE_CREATE_10MS, FILE_CREATE_UTC, ts);
    put_timestamp(e, FILE_MODIFY_TS, FILE_MODIFY_10MS, FILE_MODIFY_UTC, ts);
    put_access(e, tag_unfinished ? Timestamp {} : ts);
    uint8_t* s = e + ENTRY_BYTES;
    s[0] = TYPE_STREAM;
    s[SEC_FLAGS] = flags;
    s[STREAM_NAME_LEN] = static_cast<uint8_t>(name.size());
    put16(s + STREAM_NAME_HASH, name_hash(upcase_.up(name)));
    put64(s + STREAM_VALID_LEN, valid);
    put32(s + SEC_FIRST_CLUSTER, first);
    put64(s + SEC_DATA_LENGTH, size);
    for (uint32_t k = 0; k < names; ++k) {
        uint8_t* ne = e + static_cast<size_t>(2 + k) * ENTRY_BYTES;
        ne[0] = TYPE_NAME;
        for (uint32_t u = 0; u < NAME_UNITS_PER_ENTRY; ++u) {
            const size_t idx = static_cast<size_t>(k) * NAME_UNITS_PER_ENTRY + u;
            if (idx < name.size())
                put16(ne + 2 + 2 * u, name[idx]);
        }
    }
    put16(e + FILE_SET_CHECKSUM, entry_set_checksum(set));
    return set;
}

Node* VolumeImpl::insert_set(Node* dir, const std::u16string& name, const std::vector<uint8_t>& set, uint32_t slot)
{
    std::copy(set.begin(), set.end(), dir->data.begin() + static_cast<ptrdiff_t>(slot) * ENTRY_BYTES);
    const uint32_t count = static_cast<uint32_t>(set.size() / ENTRY_BYTES);
    dir_write(dir, slot, count);
    auto node        = std::make_unique<Node>();
    node->parent     = dir;
    node->name       = name;
    node->key        = upcase_.up(name);
    node->set_index  = slot;
    node->set_count  = count;
    unpack_set(*node, set.data());
    Node* raw = node.get();
    std::u16string key = node->key;
    dir->children.emplace(std::move(key), std::move(node));
    return raw;
}

// ---------------------------------------------------------------- lookup

Node* VolumeImpl::lookup(const std::string& path)
{
    Node* n = root_.get();
    for (const auto& part : split_path(path)) {
        if (!n->is_dir)
            fail(std::errc::not_a_directory, path);
        auto it = n->children.find(upcase_.up(utf8_to_utf16(part)));
        if (it == n->children.end())
            fail(std::errc::no_such_file_or_directory, path);
        n = it->second.get();
    }
    return n;
}

std::pair<Node*, std::u16string> VolumeImpl::resolve_parent(const std::string& path)
{
    auto parts = split_path(path);
    if (parts.empty())
        fail(std::errc::invalid_argument, "path names the root directory");
    std::u16string name = utf8_to_utf16(parts.back());
    if (!valid_name(name))
        fail(std::errc::invalid_argument, "invalid exFAT name: " + parts.back());
    parts.pop_back();
    std::string parent_path;
    for (const auto& p : parts)
        parent_path += "/" + p;
    Node* parent = lookup(parent_path);
    if (!parent->is_dir)
        fail(std::errc::not_a_directory, parent_path);
    if (parent->children.count(upcase_.up(name)))
        fail(std::errc::file_exists, path);
    return {parent, name};
}

DirEntryInfo VolumeImpl::describe(const Node* n) const
{
    DirEntryInfo d;
    d.name       = n->is_root ? "/" : utf16_to_utf8(n->name);
    d.is_dir     = n->is_dir;
    d.unfinished = !n->is_root && n->unfinished();
    d.attributes = n->attributes;
    d.size       = n->size;
    d.valid_size = n->valid_size;
    if (!n->is_root) {
        const uint8_t* e = n->parent->entry(n->set_index);
        d.mtime = unix_seconds({get32(e + FILE_MODIFY_TS), e[FILE_MODIFY_10MS], e[FILE_MODIFY_UTC]});
    }
    return d;
}

void VolumeImpl::for_each_node(Node* dir, const std::function<void(Node*)>& fn)
{
    std::vector<Node*> stack {dir};
    while (!stack.empty()) {
        Node* d = stack.back();
        stack.pop_back();
        for (auto& [key, child] : d->children) {
            fn(child.get());
            if (child->is_dir)
                stack.push_back(child.get());
        }
    }
}

std::vector<DirEntryInfo> VolumeImpl::list(const std::string& path)
{
    Node* n = lookup(path);
    if (!n->is_dir)
        return {describe(n)};
    std::vector<DirEntryInfo> out;
    for (const auto& [key, child] : n->children)
        out.push_back(describe(child.get()));
    std::sort(out.begin(), out.end(), [](const DirEntryInfo& a, const DirEntryInfo& b) { return a.name < b.name; });
    return out;
}

DirEntryInfo VolumeImpl::stat(const std::string& path) { return describe(lookup(path)); }

bool VolumeImpl::exists(const std::string& path)
{
    try {
        lookup(path);
        return true;
    } catch (const std::system_error& e) {
        if (e.code() == std::errc::no_such_file_or_directory || e.code() == std::errc::not_a_directory)
            return false;
        throw;
    }
}

FileExtents VolumeImpl::extents(const std::string& path)
{
    Node* n = lookup(path);
    if (n->is_dir)
        fail(std::errc::is_a_directory, path);
    FileExtents fe;
    fe.size       = n->size;
    fe.valid_size = n->valid_size;
    fe.extents    = runs_to_extents(node_runs(n), div_ceil<uint64_t>(n->size, LBA_BYTES));
    return fe;
}

// ---------------------------------------------------------------- state

void VolumeImpl::ensure_writable() const
{
    if (opts_.read_only)
        fail(std::errc::read_only_file_system, "volume opened read-only");
    if (closed_)
        fail(std::errc::bad_file_descriptor, "volume closed");
    if (needs_recover_)
        fail(std::errc::device_or_resource_busy, "volume is dirty: run recover() first");
}

void VolumeImpl::ensure_open_writable() const
{
    if (opts_.read_only || closed_)
        fail(std::errc::read_only_file_system, "volume not writable");
}

Output VolumeImpl::make_output(Node* n, const std::string& path, const std::vector<Run>& runs) const
{
    Output out;
    out.handle         = n->output;
    out.path           = path;
    out.reserved_bytes = n->size;
    out.extents        = runs_to_extents(runs, UINT64_MAX);
    return out;
}

void VolumeImpl::write_boot_flags(bool dirty)
{
    uint16_t flags = get16(&boot_[VOL_FLAGS_OFFSET]);
    flags = dirty ? (flags | VOLUME_DIRTY) : (flags & static_cast<uint16_t>(~VOLUME_DIRTY));
    put16(&boot_[VOL_FLAGS_OFFSET], flags);
    boot_[PERCENT_IN_USE_OFF] = static_cast<uint8_t>((static_cast<uint64_t>(cluster_count_) - free_count_) * 100 / cluster_count_);
    dev_->write(part_off_, boot_);
    dev_->flush();
    dirty_on_disk_ = dirty;
}

void VolumeImpl::ensure_dirty()
{
    if (!dirty_on_disk_)
        write_boot_flags(true);
}

void VolumeImpl::maybe_clear_dirty()
{
    if (dirty_on_disk_ && outputs_.empty() && staged_.empty() && orphan_unfinished_ == 0 && !needs_recover_ &&
        !opts_.read_only)
        write_boot_flags(false);
}

VolumeImpl::OutputState& VolumeImpl::output_state(const Output& out)
{
    auto it = outputs_.find(out.handle);
    if (it == outputs_.end())
        fail(std::errc::invalid_argument, "unknown output handle for " + out.path);
    if (it->second.staged)
        fail(std::errc::operation_in_progress, "output already finalized or abandoned: " + out.path);
    return it->second;
}

VolumeInfo VolumeImpl::info() const
{
    VolumeInfo vi;
    vi.partition_offset_bytes = part_off_;
    vi.heap_offset_bytes      = heap_offset();
    vi.cluster_bytes          = cluster_bytes_;
    vi.cluster_count          = cluster_count_;
    vi.free_clusters          = static_cast<uint32_t>(free_count_);
    vi.dirty                  = dirty_on_disk_;
    for_each_node(root_.get(), [&](Node* n) {
        ++(n->is_dir ? vi.directories : vi.files);
        if (!(n->flags & FLAG_NO_FAT_CHAIN) && n->size > 0)
            ++vi.fat_chain_files;
    });
    return vi;
}

// ---------------------------------------------------------------- open

void VolumeImpl::load()
{
    if (dev_->size() < 2 * BOOT_REGION_SECS * SECTOR_BYTES)
        fail(std::errc::invalid_argument, "device too small");
    std::array<uint8_t, SECTOR_BYTES> sec {};
    dev_->read(0, sec);
    uint64_t part_len = dev_->size();
    if (std::memcmp(&sec[3], "EXFAT   ", 8) != 0) {
        std::array<uint8_t, SECTOR_BYTES> hdr {};
        dev_->read(SECTOR_BYTES, hdr);
        if (std::memcmp(hdr.data(), "EFI PART", 8) != 0)
            fail(std::errc::invalid_argument, "neither an exFAT boot sector nor a GPT at the device start");
        const uint32_t hsize = get32(&hdr[12]);
        if (hsize < 92 || hsize > SECTOR_BYTES)
            corrupt("GPT header size");
        auto hcopy = hdr;
        put32(&hcopy[16], 0);
        if (crc32(std::span(hcopy.data(), hsize)) != get32(&hdr[16]))
            corrupt("GPT header CRC");
        const uint64_t ent_lba = get64(&hdr[72]);
        const uint32_t ent_num = get32(&hdr[80]);
        const uint32_t ent_sz  = get32(&hdr[84]);
        if (ent_sz < 128 || ent_num > 4096)
            corrupt("GPT partition array geometry");
        std::vector<uint8_t> ents(static_cast<size_t>(ent_num) * ent_sz);
        dev_->read(ent_lba * SECTOR_BYTES, ents);
        if (crc32(ents) != get32(&hdr[88]))
            corrupt("GPT partition array CRC");
        bool found = false;
        for (uint32_t i = 0; i < ent_num && !found; ++i) {
            const uint8_t* p = &ents[static_cast<size_t>(i) * ent_sz];
            if (all_zero(std::span(p, 16)))
                continue;
            const uint64_t first = get64(p + 32);
            const uint64_t last  = get64(p + 40);
            if (last < first || (last + 1) * SECTOR_BYTES > dev_->size())
                continue;
            dev_->read(first * SECTOR_BYTES, sec);
            if (std::memcmp(&sec[3], "EXFAT   ", 8) == 0) {
                part_off_ = first * SECTOR_BYTES;
                part_len  = (last - first + 1) * SECTOR_BYTES;
                found     = true;
            }
        }
        if (!found)
            fail(std::errc::invalid_argument, "no exFAT partition in the GPT");
    }

    std::vector<uint8_t> region(2 * BOOT_REGION_SECS * SECTOR_BYTES);
    dev_->read(part_off_, region);
    const uint8_t* b = region.data();
    static constexpr uint8_t JUMP[] = {0xEB, 0x76, 0x90};
    if (std::memcmp(b, JUMP, 3) != 0 || std::memcmp(b + 3, "EXFAT   ", 8) != 0 || b[510] != 0x55 || b[511] != 0xAA)
        corrupt("boot sector signature");
    if (!all_zero(std::span(b + 11, 53)))
        corrupt("boot sector MustBeZero field");
    if (b[108] != SECTOR_SHIFT)
        fail(std::errc::not_supported, "only 512 B logical sectors are supported");
    if (b[110] != 1)
        fail(std::errc::not_supported, "TexFAT (two FATs) is not supported");
    if (b[105] != 1)
        fail(std::errc::not_supported, "unsupported exFAT revision");
    const size_t region_bytes = (BOOT_REGION_SECS - 1) * SECTOR_BYTES;
    const uint32_t sum_main = boot_checksum(std::span(b, region_bytes));
    auto check_sum_sector = [&](const uint8_t* region, const char* what) {
        for (uint32_t k = 0; k < SECTOR_BYTES / sizeof(uint32_t); ++k)
            if (get32(region + region_bytes + sizeof(uint32_t) * k) != sum_main)
                corrupt(what);
    };
    check_sum_sector(b, "main boot region checksum");
    const uint8_t* bb = b + BOOT_REGION_SECS * SECTOR_BYTES;
    check_sum_sector(bb, "backup boot region does not match the main one");
    for (size_t i = 0; i < region_bytes; ++i) {
        if (boot_checksum_skips(i))
            continue;
        if (b[i] != bb[i])
            corrupt("backup boot region does not match the main one");
    }
    std::copy(b, b + SECTOR_BYTES, boot_.begin());

    const uint64_t vol_len = get64(b + 72);
    fat_off_sec_   = get32(b + 80);
    fat_len_sec_   = get32(b + 84);
    heap_off_sec_  = get32(b + 88);
    cluster_count_ = get32(b + 92);
    root_cluster_  = get32(b + 96);
    cluster_shift_ = SECTOR_SHIFT + b[109];
    if (b[109] > 25 || cluster_shift_ > 25)
        corrupt("cluster size");
    cluster_bytes_ = 1u << cluster_shift_;
    if (vol_len * SECTOR_BYTES > part_len || fat_off_sec_ < 2 * BOOT_REGION_SECS || heap_off_sec_ < fat_off_sec_ + fat_len_sec_ ||
        static_cast<uint64_t>(fat_len_sec_) * SECTOR_BYTES <
            (static_cast<uint64_t>(cluster_count_) + FIRST_CLUSTER) * FAT_ENTRY_BYTES ||
        heap_off_sec_ + (static_cast<uint64_t>(cluster_count_) << b[109]) > vol_len || cluster_count_ == 0 ||
        !valid_cluster(root_cluster_))
        corrupt("boot sector geometry");
    const uint16_t vflags = get16(b + VOL_FLAGS_OFFSET);
    if (vflags & 0x0001)
        fail(std::errc::not_supported, "second FAT active");

    const uint64_t stripe = static_cast<uint64_t>(opts_.drives) * opts_.chunk_bytes;
    if (cluster_bytes_ != stripe)
        fail(std::errc::invalid_argument, "cluster size " + std::to_string(cluster_bytes_) + " differs from the stripe " +
                                              std::to_string(stripe));
    if (heap_offset() % stripe != 0)
        fail(std::errc::invalid_argument, "cluster heap is not stripe aligned on the device");
    dirty_on_disk_ = (vflags & VOLUME_DIRTY) != 0;
    needs_recover_ = dirty_on_disk_ && !opts_.read_only && !opts_.continue_session;

    root_          = std::make_unique<Node>();
    root_->is_root = true;
    root_->is_dir  = true;
    root_->attributes = ATTR_DIRECTORY;
    const auto& rr = node_runs(root_.get());
    uint64_t root_bytes = 0;
    for (const auto& r : rr)
        root_bytes += static_cast<uint64_t>(r.len) << cluster_shift_;
    root_->data = read_runs(rr, root_bytes);

    bool have_bitmap = false;
    bool have_upcase = false;
    uint32_t upcase_sum = 0;
    for (size_t off = 0; off < root_->data.size(); off += ENTRY_BYTES) {
        const uint8_t* e = &root_->data[off];
        if (e[0] == TYPE_EOD)
            break;
        if (e[0] == TYPE_BITMAP && !(e[1] & 1)) {
            bitmap_alloc_ = {get32(e + SEC_FIRST_CLUSTER), get64(e + SEC_DATA_LENGTH), false};
            have_bitmap   = true;
        } else if (e[0] == TYPE_UPCASE) {
            upcase_alloc_ = {get32(e + SEC_FIRST_CLUSTER), get64(e + SEC_DATA_LENGTH), false};
            upcase_sum    = get32(e + 4);
            have_upcase   = true;
        }
    }
    if (!have_bitmap || !have_upcase)
        corrupt("allocation bitmap or up-case table entry missing");
    const uint32_t bitmap_bytes = div_ceil(cluster_count_, 8u);
    if (bitmap_alloc_.bytes < bitmap_bytes)
        corrupt("allocation bitmap too short");
    bitmap_runs_ = alloc_runs(bitmap_alloc_);
    bitmap_      = read_runs(bitmap_runs_, bitmap_alloc_.bytes);
    bitmap_.resize(bitmap_bytes);
    upcase_runs_ = alloc_runs(upcase_alloc_);
    const auto upcase_raw = read_runs(upcase_runs_, upcase_alloc_.bytes);
    if (table_checksum(upcase_raw) != upcase_sum)
        corrupt("up-case table checksum");
    upcase_.load(upcase_raw);

    load_tree();
    build_free_index();
    for_each_node(root_.get(), [&](Node* n) { orphan_unfinished_ += n->unfinished(); });
}

// ---------------------------------------------------------------- mutation

void VolumeImpl::make_directory(const std::string& path)
{
    ensure_writable();
    auto [parent, name] = resolve_parent(path);
    ensure_dirty();
    const uint32_t slot = claim_slots(parent, file_set_count(name.size()));
    const auto runs = allocate(1);
    const uint32_t c = runs[0].start;
    zero_cluster(c);
    bits_set(runs[0], true);
    bitmap_write_dirty();
    dev_->flush();
    const auto set = build_set(name, ATTR_DIRECTORY, FLAG_ALLOC_POSSIBLE | FLAG_NO_FAT_CHAIN, c, cluster_bytes_,
                               cluster_bytes_, now_timestamp(), false);
    Node* n = insert_set(parent, name, set, slot);
    n->runs       = runs;
    n->runs_known = true;
    n->data.assign(cluster_bytes_, 0);
    dev_->flush();
}

void VolumeImpl::remove(const std::string& path)
{
    ensure_writable();
    Node* n = lookup(path);
    if (n->is_root)
        fail(std::errc::invalid_argument, "cannot remove the root directory");
    if (n->output != 0 || n->busy)
        fail(std::errc::device_or_resource_busy, path);
    if (n->is_dir && !n->children.empty())
        fail(std::errc::directory_not_empty, path);
    ensure_dirty();
    n->busy = true;
    staged_.push_back({StagedKind::REMOVE, n, 0, 0, {}});
}

Output VolumeImpl::reserve(const std::string& path, uint64_t nbytes)
{
    ensure_writable();
    auto [parent, name] = resolve_parent(path);
    const uint64_t n = clusters_for(nbytes);
    if (n > free_count_)
        fail(std::errc::no_space_on_device, "cannot reserve " + std::to_string(nbytes) + " B for " + path);
    ensure_dirty();
    const uint32_t slot = claim_slots(parent, file_set_count(name.size()));
    auto runs = allocate(n);
    for (const auto& r : runs)
        bits_set(r, true);
    bitmap_write_dirty();
    if (runs.size() > 1) {
        write_chain(runs);
        fat_write_dirty();
    }
    uint8_t flags = FLAG_ALLOC_POSSIBLE;
    if (runs.size() == 1)
        flags |= FLAG_NO_FAT_CHAIN;
    const uint64_t size = n << cluster_shift_;
    const auto set = build_set(name, ATTR_ARCHIVE, flags, runs.empty() ? 0 : runs[0].start, size, 0, now_timestamp(), true);
    Node* node = insert_set(parent, name, set, slot);
    node->runs       = runs;
    node->runs_known = true;
    node->output     = next_handle_++;
    outputs_[node->output] = {node, runs, false};
    unflushed_ = true;

    return make_output(node, path, runs);
}

std::vector<Extent> VolumeImpl::extend(Output& output, uint64_t nbytes)
{
    ensure_writable();
    auto& st = output_state(output);
    const uint64_t n = clusters_for(nbytes);
    if (n == 0)
        return {};
    if (n > free_count_)
        fail(std::errc::no_space_on_device, "cannot extend " + output.path);
    Node* node = st.node;
    std::vector<Run> added;
    uint64_t rem = n;
    if (!st.runs.empty()) {
        const uint32_t last = st.runs.back().last();
        auto adj = free_by_start_.find(last + 1);
        if (adj != free_by_start_.end()) {
            const auto take = static_cast<uint32_t>(std::min<uint64_t>(adj->second, rem));
            free_take(last + 1, take);
            added.push_back({last + 1, take});
            rem -= take;
        }
    }
    if (rem > 0) {
        auto more = allocate(rem);
        added.insert(added.end(), more.begin(), more.end());
    }
    for (const auto& r : added)
        bits_set(r, true);
    bitmap_write_dirty();

    const bool was_empty  = st.runs.empty();
    const bool was_no_fat = (node->flags & FLAG_NO_FAT_CHAIN) != 0;
    std::vector<Run> merged = st.runs;
    for (const auto& r : added)
        append_run(merged, r);
    if (merged.size() > 1) {
        if (was_empty || was_no_fat) {
            write_chain(merged);
        } else {
            fat_set(st.runs.back().last(), added.front().start);
            write_chain(added);
        }
        fat_write_dirty();
        node->flags &= static_cast<uint8_t>(~FLAG_NO_FAT_CHAIN);
    } else {
        node->flags |= FLAG_NO_FAT_CHAIN;
    }
    node->first_cluster = merged.front().start;
    node->size += n << cluster_shift_;
    update_stream(node);
    dir_write(node->parent, node->set_index, node->set_count);
    st.runs    = merged;
    node->runs = merged;
    dev_->flush();
    unflushed_ = false;

    output.reserved_bytes = node->size;
    output.extents        = runs_to_extents(merged, UINT64_MAX);
    return runs_to_extents(added, UINT64_MAX);
}

void VolumeImpl::finalize(Output& output, uint64_t nbytes)
{
    ensure_writable();
    auto& st = output_state(output);
    if (nbytes > st.node->size)
        fail(std::errc::invalid_argument, "finalize beyond the reservation of " + output.path);
    st.staged = true;
    staged_.push_back({StagedKind::FINALIZE, st.node, output.handle, nbytes, now_timestamp()});
}

void VolumeImpl::abandon(Output& output)
{
    ensure_writable();
    auto& st = output_state(output);
    st.staged = true;
    staged_.push_back({StagedKind::ABANDON, st.node, output.handle, 0, {}});
}

Output VolumeImpl::adopt(const std::string& path)
{
    ensure_open_writable();
    Node* n = lookup(path);
    if (!n->unfinished() || n->output != 0 || n->busy)
        fail(std::errc::invalid_argument, "not an unfinished output: " + path);
    const auto runs = node_runs(n);
    n->output = next_handle_++;
    outputs_[n->output] = {n, runs, false};
    --orphan_unfinished_;
    needs_recover_ = false;
    return make_output(n, path, runs);
}

void VolumeImpl::commit()
{
    ensure_open_writable();
    if (staged_.empty()) {
        maybe_clear_dirty();
        return;
    }
    dev_->flush();
    std::vector<Run> freed;
    for (const auto& op : staged_) {
        Node* node = op.node;
        if (op.kind == StagedKind::FINALIZE) {
            auto& runs = outputs_.at(op.handle).runs;
            const uint64_t keep = clusters_for(op.nbytes);
            const bool fat_chain = !(node->flags & FLAG_NO_FAT_CHAIN) && !runs.empty();
            std::vector<Run> kept;
            std::vector<Run> dropped;
            uint64_t seen = 0;
            for (const auto& r : runs) {
                if (seen >= keep) {
                    dropped.push_back(r);
                } else if (seen + r.len > keep) {
                    const auto k = static_cast<uint32_t>(keep - seen);
                    kept.push_back({r.start, k});
                    dropped.push_back({r.start + k, r.len - k});
                } else {
                    kept.push_back(r);
                }
                seen += r.len;
            }
            if (fat_chain) {
                if (!kept.empty())
                    fat_set(kept.back().last(), FAT_EOC);
                for (const auto& r : dropped)
                    fat_free(r);
            }
            freed.insert(freed.end(), dropped.begin(), dropped.end());
            node->size = node->valid_size = op.nbytes;
            if (kept.empty()) {
                node->first_cluster = 0;
                node->flags         = FLAG_ALLOC_POSSIBLE;
            }
            uint8_t* e = set_ptr(node);
            put_timestamp(e, FILE_MODIFY_TS, FILE_MODIFY_10MS, FILE_MODIFY_UTC, op.ts);
            put_access(e, op.ts);
            node->access_ts = op.ts.stamp;
            update_stream(node);
            dir_write(node->parent, node->set_index, node->set_count);
            node->runs   = kept;
            node->output = 0;
            outputs_.erase(op.handle);
        } else {
            std::vector<Run> runs = op.kind == StagedKind::ABANDON ? outputs_.at(op.handle).runs : node_runs(node);
            if (op.kind == StagedKind::REMOVE)
                for (const auto& a : node->extra_allocs) {
                    auto extra = alloc_runs(a);
                    runs.insert(runs.end(), extra.begin(), extra.end());
                }
            if (op.kind == StagedKind::ABANDON && !(node->flags & FLAG_NO_FAT_CHAIN))
                for (const auto& r : runs)
                    fat_free(r);
            freed.insert(freed.end(), runs.begin(), runs.end());
            if (op.kind == StagedKind::ABANDON)
                outputs_.erase(op.handle);
            else if (node->unfinished())
                --orphan_unfinished_;
            delete_set(node);
        }
    }
    staged_.clear();
    fat_write_dirty();
    for (const auto& r : freed)
        bits_set(r, false);
    bitmap_write_dirty();
    dev_->flush();
    for (const auto& r : freed) {
        dev_->discard(cluster_off(r.start), static_cast<uint64_t>(r.len) << cluster_shift_);
        free_insert(r);
    }
    maybe_clear_dirty();
}

void VolumeImpl::flush()
{
    dev_->flush();
    unflushed_ = false;
}

// ---------------------------------------------------------------- check and recover

std::vector<uint8_t> VolumeImpl::owner_bits(uint64_t& cross)
{
    std::vector<uint8_t> bits(bitmap_.size(), 0);
    cross = 0;
    auto mark = [&](const std::vector<Run>& runs) {
        for (const auto& r : runs)
            for (uint32_t c = r.start; c < r.end(); ++c) {
                const uint32_t i = c - FIRST_CLUSTER;
                if (bit_test(bits, i))
                    ++cross;
                bit_assign(bits, i, true);
            }
    };
    mark(bitmap_runs_);
    mark(upcase_runs_);
    mark(node_runs(root_.get()));
    for_each_node(root_.get(), [&](Node* n) {
        mark(node_runs(n));
        for (const auto& a : n->extra_allocs)
            mark(alloc_runs(a));
    });
    return bits;
}

CheckReport VolumeImpl::check()
{
    CheckReport rep;
    uint64_t cross = 0;
    const auto owners = owner_bits(cross);
    const auto disk   = read_runs(bitmap_runs_, bitmap_.size());
    rep.cross_linked = cross;
    for (uint32_t i = 0; i < cluster_count_; ++i) {
        const bool o = bit_test(owners, i);
        const bool d = bit_test(disk, i);
        rep.owned_clusters += o;
        rep.leaked_clusters += d && !o;
        rep.missing_clusters += o && !d;
    }
    return rep;
}

RecoverReport VolumeImpl::recover()
{
    ensure_open_writable();
    if (!outputs_.empty() || !staged_.empty())
        fail(std::errc::device_or_resource_busy, "recover() with live outputs or staged operations");
    RecoverReport rep;
    ensure_dirty();

    // A lost reserve write can leave a later set behind the end-of-directory marker; only uncommitted reserves end up there.
    std::vector<Node*> dirs {root_.get()};
    for_each_node(root_.get(), [&](Node* n) {
        if (n->is_dir)
            dirs.push_back(n);
    });
    for (Node* d : dirs) {
        const uint32_t total = d->entry_count();
        uint32_t eod = 0;
        while (eod < total && *d->entry(eod) != TYPE_EOD)
            ++eod;
        for (uint32_t j = eod + 1; j < total; ++j) {
            uint8_t* e = d->entry(j);
            if (all_zero(std::span(e, ENTRY_BYTES)))
                continue;
            std::fill(e, e + ENTRY_BYTES, 0);
            dir_write(d, j, 1);
            ++rep.entries_past_eod;
        }
    }

    std::vector<Node*> unfinished;
    for_each_node(root_.get(), [&](Node* n) {
        if (n->unfinished())
            unfinished.push_back(n);
    });
    std::vector<uint32_t> stale_chain;
    for (Node* n : unfinished) {
        if (!(n->flags & FLAG_NO_FAT_CHAIN) && valid_cluster(n->first_cluster)) {
            uint32_t c = n->first_cluster;
            for (uint64_t i = 0; i < clusters_for(n->size) && valid_cluster(c); ++i) {
                stale_chain.push_back(c);
                c = fat_get(c);
            }
        }
        delete_set(n);
        ++rep.deleted_unfinished;
    }
    orphan_unfinished_ = 0;

    std::vector<uint32_t> tails;
    auto normalize = [&](const Alloc& a, std::vector<Run>& runs_out) {
        runs_out = alloc_runs(a);
        if (a.no_fat || runs_out.empty())
            return;
        const uint32_t last = runs_out.back().last();
        const uint32_t next = fat_get(last);
        if (next != FAT_EOC) {
            fat_set(last, FAT_EOC);
            tails.push_back(next);
            ++rep.truncated_chains;
        }
    };
    normalize(bitmap_alloc_, bitmap_runs_);
    normalize(upcase_alloc_, upcase_runs_);
    for_each_node(root_.get(), [&](Node* n) {
        normalize(n->alloc(), n->runs);
        n->runs_known = true;
    });

    uint64_t cross = 0;
    const auto owners = owner_bits(cross);
    if (cross != 0)
        corrupt(std::to_string(cross) + " cross-linked clusters; run fsck.exfat");
    auto owned = [&](uint32_t c) { return bit_test(owners, c - FIRST_CLUSTER); };
    for (uint32_t t : tails) {
        for (uint32_t k = 0; valid_cluster(t) && !owned(t) && k < cluster_count_; ++k) {
            const uint32_t next = fat_get(t);
            fat_set(t, 0);
            t = next;
        }
    }
    for (uint32_t c : stale_chain)
        if (!owned(c) && fat_get(c) != 0)
            fat_set(c, 0);
    fat_write_dirty();

    for (uint32_t c = FIRST_CLUSTER; c < cluster_count_ + FIRST_CLUSTER; ++c) {
        const bool o = owned(c);
        if (o == bit_get(c))
            continue;
        bits_set({c, 1}, o);
        if (o)
            ++rep.bits_set;
        else
            ++rep.bits_cleared;
    }
    bitmap_write_dirty();
    build_free_index();
    dev_->flush();
    needs_recover_ = false;
    maybe_clear_dirty();
    return rep;
}

void VolumeImpl::close()
{
    if (closed_)
        return;
    if (!opts_.read_only) {
        staged_.clear();
        if (outputs_.empty())
            maybe_clear_dirty();
        dev_->flush();
    }
    closed_ = true;
}

} // namespace

std::unique_ptr<Volume> Volume::open(std::unique_ptr<BlockDevice> dev, VolumeOptions opts)
{
    auto v = std::make_unique<VolumeImpl>(std::move(dev), opts);
    v->load();
    return v;
}

} // namespace iuv_exfat
