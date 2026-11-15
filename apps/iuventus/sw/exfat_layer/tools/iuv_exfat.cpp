// iuv_exfat.cpp: iuv-exfat command line tool for the Iuventus exFAT file layer
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#include <algorithm>
#include <bit>
#include <cinttypes>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <functional>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#include "iuv_exfat/digest_fill_run.hpp"
#include "iuv_exfat/job.hpp"
#include "iuv_exfat/util.hpp"
#include "iuv_exfat/volume.hpp"

using namespace iuv_exfat;

namespace {

constexpr size_t IO_CHUNK = 8u << 20;

void usage()
{
    std::cerr <<
        "usage: iuv-exfat [--drives N] [--chunk-kib K] <command> <device> [args]\n"
        "       (<device> <command> [args] is accepted as well)\n"
        "commands:\n"
        "  info                       volume geometry and state\n"
        "  ls [-R] [path]             list a directory\n"
        "  extents <path>             'size <bytes>', then one '<lba> <count>' line per extent\n"
        "  mkdir <path>               create a directory\n"
        "  put <host-file> <path>     copy a host file onto the volume\n"
        "  get <path> <host-file>     copy a file off the volume\n"
        "  rm <path>                  remove a file or an empty directory\n"
        "  mv <path> <new-path>       rename, replacing a file or an empty directory\n"
        "  check                      compare the allocation bitmap with its owners\n"
        "  recover                    crash cleanup, then clear VolumeDirty\n"
        "  reserve <path> <bytes>     reserve and flush, print '<lba> <count>' lines, leave it unfinished\n"
        "  finalize <path> <bytes>    adopt an unfinished output, finalize and commit it\n"
        "  run [opts] <out> <in>... [-- <out> <in>...]   one DIGEST_FILL job, up to 8 streams\n"
        "      --fill-bytes N --seed S --reserve B --extend B --model-seed S\n"
        "      --card DEV [--compatible C]   use the card instead of the software model\n";
}

void print_ls(Volume& vol, const std::string& path, bool recursive)
{
    for (const auto& e : vol.list(path)) {
        const std::string full = (path == "/" || path.empty() ? "" : path) + "/" + e.name;
        std::printf("%c%c %14" PRIu64 " %s\n", e.is_dir ? 'd' : '-', e.unfinished ? 'U' : '-', e.size, full.c_str());
        if (recursive && e.is_dir)
            print_ls(vol, full, true);
    }
}

int cmd_put(Volume& vol, const std::string& host, const std::string& path)
{
    std::ifstream in(host, std::ios::binary | std::ios::ate);
    if (!in)
        throw std::runtime_error("cannot open " + host);
    const uint64_t size = static_cast<uint64_t>(in.tellg());
    in.seekg(0);
    Output out = vol.reserve(path, size);
    std::vector<uint8_t> buf(IO_CHUNK);
    uint64_t off = 0;
    while (off < size) {
        const size_t n = static_cast<size_t>(std::min<uint64_t>(IO_CHUNK, size - off));
        in.read(reinterpret_cast<char*>(buf.data()), static_cast<std::streamsize>(n));
        if (!in)
            throw std::runtime_error("short read on " + host);
        write_extents(vol.device(), out.extents, off, std::span<const uint8_t>(buf.data(), n));
        off += n;
    }
    vol.finalize(out, size);
    vol.commit();
    return 0;
}

int cmd_get(Volume& vol, const std::string& path, const std::string& host)
{
    const auto fe = vol.extents(path);
    std::ofstream out(host, std::ios::binary | std::ios::trunc);
    if (!out)
        throw std::runtime_error("cannot create " + host);
    std::vector<uint8_t> buf(IO_CHUNK);
    for (uint64_t pos = 0; pos < fe.size; pos += IO_CHUNK) {
        const uint64_t n     = std::min<uint64_t>(IO_CHUNK, fe.size - pos);
        const uint64_t valid = pos < fe.valid_size ? std::min(n, fe.valid_size - pos) : 0;
        std::fill(buf.begin() + static_cast<ptrdiff_t>(valid), buf.begin() + static_cast<ptrdiff_t>(n), 0);
        for_each_dev_range(fe.extents, pos, valid, [&](uint64_t dev_off, uint64_t at, uint64_t len) {
            vol.device().read(dev_off, std::span(buf.data() + at, len));
        });
        out.write(reinterpret_cast<const char*>(buf.data()), static_cast<std::streamsize>(n));
    }
    return out ? 0 : 1;
}

int cmd_run(Volume& vol, const std::vector<std::string>& args)
{
    const auto run = parse_digest_fill_run(args);
    // Opened ahead of the reservations, which a card that fails to open would otherwise leave behind.
    std::unique_ptr<MiBus> card;
    if (!run.card.empty())
        card = open_nfb_mi_bus(run.card, run.compatible);
    auto outs = reserve_digest_fill_outputs(vol, run);
    const auto res = run_digest_fill(vol, run, outs, card.get(), &vol.device());
    vol.commit();
    std::fputs(digest_fill_report(vol, run, res).c_str(), stdout);
    if (!res.ok) {
        std::fprintf(stderr, "job failed: %s\n", res.error.c_str());
        return 1;
    }
    return 0;
}

} // namespace

int main(int argc, char** argv)
{
    std::vector<std::string> args(argv + 1, argv + argc);
    VolumeOptions vo;
    size_t i = 0;
    try {
        while (i < args.size() && args[i].rfind("--", 0) == 0) {
            if (args[i] == "--drives" && i + 1 < args.size()) {
                vo.drives = static_cast<uint32_t>(parse_u64(args[i + 1], UINT32_MAX));
                i += 2;
            } else if (args[i] == "--chunk-kib" && i + 1 < args.size()) {
                vo.chunk_bytes = static_cast<uint32_t>(parse_u64(args[i + 1], UINT32_MAX / 1024) * 1024);
                i += 2;
            } else {
                usage();
                return 2;
            }
        }
    } catch (const std::exception& e) {
        std::fprintf(stderr, "iuv-exfat: %s\n", e.what());
        return 2;
    }
    if (args.size() < i + 2) {
        usage();
        return 2;
    }
    static const char* const COMMANDS[] = {"info", "ls", "extents", "mkdir", "put", "get", "rm", "mv",
                                           "check", "recover", "run", "reserve", "finalize"};
    const bool cmd_first = std::find(std::begin(COMMANDS), std::end(COMMANDS), args[i]) != std::end(COMMANDS);
    const std::string dev = cmd_first ? args[i + 1] : args[i];
    const std::string cmd = cmd_first ? args[i] : args[i + 1];
    std::vector<std::string> rest(args.begin() + static_cast<ptrdiff_t>(i + 2), args.end());
    try {
        const bool ro = cmd == "info" || cmd == "ls" || cmd == "extents" || cmd == "get" || cmd == "check";
        vo.read_only = ro;
        // reserve and finalize are separate processes of one bench session, so the dirty volume is not a crash.
        vo.continue_session = cmd == "reserve" || cmd == "finalize";
        auto vol = Volume::open(open_block_device(dev, ro), vo);
        int rc = 0;
        if (cmd == "info") {
            const auto vi = vol->info();
            std::printf("partition offset %" PRIu64 " B\nheap offset %" PRIu64 " B\ncluster %u B\nclusters %u\nfree %u\n"
                        "directories %u\nfiles %u\nfat-chain files %u\ndirty %s\n",
                        vi.partition_offset_bytes, vi.heap_offset_bytes, vi.cluster_bytes, vi.cluster_count,
                        vi.free_clusters, vi.directories, vi.files, vi.fat_chain_files, vi.dirty ? "yes" : "no");
        } else if (cmd == "ls") {
            bool rec = false;
            std::string path = "/";
            for (const auto& a : rest) {
                if (a == "-R")
                    rec = true;
                else
                    path = a;
            }
            print_ls(*vol, path, rec);
        } else if (cmd == "extents" && rest.size() == 1) {
            const auto fe = vol->extents(rest[0]);
            std::printf("size %" PRIu64 "\n", fe.size);
            for (const auto& e : fe.extents)
                std::printf("%" PRIu64 " %u\n", e.lba, e.count);
        } else if (cmd == "reserve" && rest.size() == 2) {
            const Output out = vol->reserve(rest[0], parse_u64(rest[1]));
            vol->flush();
            for (const auto& e : out.extents)
                std::printf("%" PRIu64 " %u\n", e.lba, e.count);
        } else if (cmd == "finalize" && rest.size() == 2) {
            Output out = vol->adopt(rest[0]);
            vol->finalize(out, parse_u64(rest[1]));
            vol->commit();
        } else if (cmd == "mkdir" && rest.size() == 1) {
            vol->make_directory(rest[0]);
        } else if (cmd == "put" && rest.size() == 2) {
            rc = cmd_put(*vol, rest[0], rest[1]);
        } else if (cmd == "get" && rest.size() == 2) {
            rc = cmd_get(*vol, rest[0], rest[1]);
        } else if (cmd == "rm" && rest.size() == 1) {
            vol->remove(rest[0]);
            vol->commit();
        } else if (cmd == "mv" && rest.size() == 2) {
            vol->rename(rest[0], rest[1]);
            vol->commit();
        } else if (cmd == "check") {
            const auto r = vol->check();
            std::printf("owned %" PRIu64 " leaked %" PRIu64 " missing %" PRIu64 " cross-linked %" PRIu64 "\n",
                        r.owned_clusters, r.leaked_clusters, r.missing_clusters, r.cross_linked);
            rc = r.clean() ? 0 : 1;
        } else if (cmd == "recover") {
            const auto r = vol->recover();
            std::printf("deleted unfinished %u, truncated chains %u, trimmed files %u, superseded sets %u, bits cleared %" PRIu64
                        ", bits set %" PRIu64 "\n",
                        r.deleted_unfinished, r.truncated_chains, r.trimmed_files, r.superseded_sets, r.bits_cleared,
                        r.bits_set);
        } else if (cmd == "run") {
            rc = cmd_run(*vol, rest);
        } else {
            usage();
            return 2;
        }
        vol->close();
        return rc;
    } catch (const std::exception& e) {
        std::fprintf(stderr, "iuv-exfat: %s\n", e.what());
        return 1;
    }
}
