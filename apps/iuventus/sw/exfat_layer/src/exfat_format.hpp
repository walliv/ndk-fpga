// exfat_format.hpp: exFAT on-disk constants, checksums, names and timestamps
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <algorithm>
#include <concepts>
#include <cstdint>
#include <cstring>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include "iuv_exfat/util.hpp"

namespace iuv_exfat::fmt {

constexpr uint32_t SECTOR_BYTES     = 512;
constexpr uint32_t SECTOR_SHIFT     = 9;
constexpr uint32_t BOOT_REGION_SECS = 12;
constexpr uint32_t ENTRY_BYTES      = 32;
constexpr uint32_t FIRST_CLUSTER    = 2;
constexpr uint32_t FAT_ENTRY_BYTES  = 4;
constexpr uint32_t FAT_EOC          = 0xFFFFFFFFu;
constexpr uint32_t FAT_BAD          = 0xFFFFFFF7u;
constexpr uint32_t MAX_NAME_UNITS   = 255;
constexpr uint32_t NAME_UNITS_PER_ENTRY = 15;

constexpr uint16_t VOL_FLAGS_OFFSET   = 106;
constexpr uint16_t PERCENT_IN_USE_OFF = 112;
constexpr uint16_t VOLUME_DIRTY       = 0x0002;

constexpr uint8_t TYPE_EOD     = 0x00;
constexpr uint8_t TYPE_IN_USE  = 0x80;
constexpr uint8_t TYPE_SECONDARY = 0x40;
constexpr uint8_t TYPE_BENIGN  = 0x20;
constexpr uint8_t TYPE_BITMAP  = 0x81;
constexpr uint8_t TYPE_UPCASE  = 0x82;
constexpr uint8_t TYPE_LABEL   = 0x83;
constexpr uint8_t TYPE_FILE    = 0x85;
constexpr uint8_t TYPE_STREAM  = 0xC0;
constexpr uint8_t TYPE_NAME    = 0xC1;

constexpr uint8_t FLAG_ALLOC_POSSIBLE = 0x01;
constexpr uint8_t FLAG_NO_FAT_CHAIN   = 0x02;

constexpr uint16_t ATTR_DIRECTORY = 0x0010;
constexpr uint16_t ATTR_ARCHIVE   = 0x0020;

// File entry field offsets.
constexpr uint32_t FILE_SECONDARY_COUNT = 1;
constexpr uint32_t FILE_SET_CHECKSUM    = 2;
constexpr uint32_t FILE_ATTRIBUTES      = 4;
constexpr uint32_t FILE_CREATE_TS       = 8;
constexpr uint32_t FILE_MODIFY_TS       = 12;
constexpr uint32_t FILE_ACCESS_TS       = 16;
constexpr uint32_t FILE_CREATE_10MS     = 20;
constexpr uint32_t FILE_MODIFY_10MS     = 21;
constexpr uint32_t FILE_CREATE_UTC      = 22;
constexpr uint32_t FILE_MODIFY_UTC      = 23;
constexpr uint32_t FILE_ACCESS_UTC      = 24;

// Stream extension and generic allocation secondary field offsets.
constexpr uint32_t SEC_FLAGS         = 1;
constexpr uint32_t STREAM_NAME_LEN   = 3;
constexpr uint32_t STREAM_NAME_HASH  = 4;
constexpr uint32_t STREAM_VALID_LEN  = 8;
constexpr uint32_t SEC_FIRST_CLUSTER = 20;
constexpr uint32_t SEC_DATA_LENGTH   = 24;

template <std::unsigned_integral T>
inline T get_le(const uint8_t* p)
{
    T v = 0;
    for (size_t i = sizeof(T); i-- > 0;)
        v = static_cast<T>((v << 8) | p[i]);
    return v;
}
template <std::unsigned_integral T>
inline void put_le(uint8_t* p, T v)
{
    for (size_t i = 0; i < sizeof(T); ++i)
        p[i] = static_cast<uint8_t>(v >> (8 * i));
}
inline uint16_t get16(const uint8_t* p) { return get_le<uint16_t>(p); }
inline uint32_t get32(const uint8_t* p) { return get_le<uint32_t>(p); }
inline uint64_t get64(const uint8_t* p) { return get_le<uint64_t>(p); }
inline void put16(uint8_t* p, uint16_t v) { put_le(p, v); }
inline void put32(uint8_t* p, uint32_t v) { put_le(p, v); }
inline void put64(uint8_t* p, uint64_t v) { put_le(p, v); }

constexpr bool boot_checksum_skips(size_t i)
{
    return i == VOL_FLAGS_OFFSET || i == VOL_FLAGS_OFFSET + 1 || i == PERCENT_IN_USE_OFF;
}

// Directory entries of a file entry set holding a name of the given length: file, stream and the name entries.
constexpr uint32_t name_entry_count(size_t name_units)
{
    return static_cast<uint32_t>(div_ceil(name_units, size_t {NAME_UNITS_PER_ENTRY}));
}
constexpr uint32_t file_set_count(size_t name_units) { return 2 + name_entry_count(name_units); }

inline bool all_zero(std::span<const uint8_t> bytes)
{
    return std::all_of(bytes.begin(), bytes.end(), [](uint8_t b) { return b == 0; });
}

// Excludes VolumeFlags and PercentInUse of the boot sector.
uint32_t boot_checksum(std::span<const uint8_t> region);
uint16_t entry_set_checksum(std::span<const uint8_t> set);
uint16_t name_hash(std::u16string_view upcased);
uint32_t table_checksum(std::span<const uint8_t> table);
uint32_t crc32(std::span<const uint8_t> data);

class UpcaseTable {
public:
    void load(std::span<const uint8_t> compressed);
    char16_t up(char16_t c) const { return map_[c]; }
    std::u16string up(std::u16string_view s) const;

private:
    std::vector<char16_t> map_;
};

// Throws std::invalid_argument on malformed input.
std::u16string utf8_to_utf16(std::string_view s);
std::string utf16_to_utf8(std::u16string_view s);
bool valid_name(std::u16string_view name);

struct Timestamp {
    uint32_t stamp = 0;
    uint8_t  ms10  = 0;
    uint8_t  utc   = 0;
};
// UTC with the OffsetValid bit set and offset 0.
Timestamp now_timestamp();
// Seconds since the Unix epoch; a stamp without OffsetValid is taken as UTC.
int64_t unix_seconds(const Timestamp& ts);

std::vector<std::string> split_path(std::string_view path);

} // namespace iuv_exfat::fmt
