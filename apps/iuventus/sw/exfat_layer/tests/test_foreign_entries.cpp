// test_foreign_entries.cpp: entry sets other exFAT writers produce (lone surrogate names, empty files without flags)
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#include <functional>
#include <system_error>

#include "../src/exfat_format.hpp"
#include "test_util.hpp"

using namespace iuv_exfat;
using namespace iuv_exfat::fmt;
using namespace iuv_test;

namespace {

// Rewrites the root entry set named name in place: edit changes the set, then name hash and checksum are redone.
void patch_root_set(const std::string& image, const std::u16string& name, const std::function<void(uint8_t*)>& edit)
{
    uint64_t heap = 0, part = 0;
    {
        auto vol = open_volume(image, true);
        heap = vol->info().heap_offset_bytes;
        part = vol->info().partition_offset_bytes;
    }
    auto dev = open_block_device(image);
    std::vector<uint8_t> boot(SECTOR_BYTES);
    dev->read(part, boot);
    const uint32_t root = get32(&boot[96]);
    const uint32_t cluster_bytes = 1u << (SECTOR_SHIFT + boot[109]);
    std::vector<uint8_t> dir(cluster_bytes);
    const uint64_t off = heap + static_cast<uint64_t>(root - FIRST_CLUSTER) * cluster_bytes;
    dev->read(off, dir);
    for (size_t i = 0; i + 3 * ENTRY_BYTES <= dir.size(); i += ENTRY_BYTES) {
        uint8_t* e = &dir[i];
        if (e[0] != TYPE_FILE || e[ENTRY_BYTES + STREAM_NAME_LEN] != name.size())
            continue;
        auto set_name = [&] {
            std::u16string n;
            for (size_t u = 0; u < name.size(); ++u)
                n.push_back(static_cast<char16_t>(
                    get16(e + (2 + u / NAME_UNITS_PER_ENTRY) * ENTRY_BYTES + 2 + 2 * (u % NAME_UNITS_PER_ENTRY))));
            return n;
        };
        if (set_name() != name)
            continue;
        const size_t count = 1 + e[FILE_SECONDARY_COUNT];
        edit(e);
        put16(e + ENTRY_BYTES + STREAM_NAME_HASH, name_hash(set_name()));
        put16(e + FILE_SET_CHECKSUM, entry_set_checksum(std::span(e, count * ENTRY_BYTES)));
        dev->write(off, dir);
        dev->flush();
        return;
    }
    throw TestFailure("entry set to patch not found");
}

} // namespace

int main()
{
    return run_test("test_foreign_entries", [](uint64_t seed, TempDir& tmp) {
        std::mt19937_64 rng(seed);
        const std::string image = tmp.file("vol.img");
        make_image(image, 64 * MIB);
        const auto data = random_bytes(rng, 1 + rng() % (2 * CLUSTER));
        {
            auto vol = open_volume(image);
            put_file(*vol, "/SURRX", data);
            put_file(*vol, "/EMPTY", {});
            put_file(*vol, "/keep", random_bytes(rng, 100));
            vol->close();
        }

        // Windows names may hold unpaired UTF-16 surrogates; the name listed has to reach the file again.
        patch_root_set(image, u"SURRX", [](uint8_t* e) { put16(e + 2 * ENTRY_BYTES + 2 + 2 * 4, 0xD800); });
        // Writers other than this library may leave an empty file's stream flags all clear.
        patch_root_set(image, u"EMPTY", [](uint8_t* e) { e[ENTRY_BYTES + SEC_FLAGS] = 0; });

        const auto grown = random_bytes(rng, 1 + rng() % (2 * CLUSTER));
        {
            auto vol = open_volume(image);
            std::string surr;
            for (const auto& d : vol->list("/"))
                if (d.name.rfind("SURR", 0) == 0)
                    surr = "/" + d.name;
            CHECK(!surr.empty());
            CHECK_EQ(vol->stat(surr).size, data.size());
            CHECK(read_file(*vol, surr) == data);
            vol->rename(surr, "/surr_moved");
            vol->commit();
            CHECK(read_file(*vol, "/surr_moved") == data);
            vol->rename("/surr_moved", surr);
            vol->commit();
            vol->remove(surr);
            vol->commit();
            CHECK(!vol->exists(surr));

            Output o = vol->reopen("/EMPTY");
            vol->extend(o, grown.size());
            write_extents(vol->device(), o.extents, 0, grown);
            vol->finalize(o, grown.size());
            vol->commit();
            vol->close();
        }
        check_volume(image, tmp, "foreign entries");
        auto vol = open_volume(image, true);
        CHECK(read_file(*vol, "/EMPTY") == grown);
        CHECK(vol->check().clean());
    });
}
