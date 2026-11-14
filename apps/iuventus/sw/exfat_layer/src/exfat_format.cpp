// exfat_format.cpp: exFAT checksums, up-case table, UTF conversion and timestamps
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#include "exfat_format.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <bit>
#include <ctime>
#include <stdexcept>

namespace iuv_exfat::fmt {

namespace {

constexpr uint32_t UPCASE_UNITS = 0x10000;

// exFAT checksums rotate right by one bit, then add the next byte.
template <std::unsigned_integral T>
T rotr_add(T sum, uint8_t b)
{
    return static_cast<T>(std::rotr(sum, 1) + b);
}

} // namespace

uint32_t boot_checksum(std::span<const uint8_t> region)
{
    uint32_t sum = 0;
    for (size_t i = 0; i < region.size(); ++i) {
        if (!boot_checksum_skips(i))
            sum = rotr_add(sum, region[i]);
    }
    return sum;
}

uint16_t entry_set_checksum(std::span<const uint8_t> set)
{
    uint16_t sum = 0;
    for (size_t i = 0; i < set.size(); ++i) {
        if (i == FILE_SET_CHECKSUM || i == FILE_SET_CHECKSUM + 1)
            continue;
        sum = rotr_add(sum, set[i]);
    }
    return sum;
}

uint16_t name_hash(std::u16string_view upcased)
{
    uint16_t hash = 0;
    for (char16_t c : upcased) {
        for (uint8_t b : {static_cast<uint8_t>(c & 0xFF), static_cast<uint8_t>(c >> 8)})
            hash = rotr_add(hash, b);
    }
    return hash;
}

uint32_t table_checksum(std::span<const uint8_t> table)
{
    uint32_t sum = 0;
    for (uint8_t b : table)
        sum = rotr_add(sum, b);
    return sum;
}

uint32_t crc32(std::span<const uint8_t> data)
{
    static const std::array<uint32_t, 256> TABLE = [] {
        std::array<uint32_t, 256> t {};
        for (uint32_t i = 0; i < 256; ++i) {
            uint32_t c = i;
            for (int k = 0; k < 8; ++k)
                c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            t[i] = c;
        }
        return t;
    }();
    uint32_t crc = 0xFFFFFFFFu;
    for (uint8_t b : data)
        crc = TABLE[(crc ^ b) & 0xFF] ^ (crc >> 8);
    return crc ^ 0xFFFFFFFFu;
}

void UpcaseTable::load(std::span<const uint8_t> compressed)
{
    map_.resize(UPCASE_UNITS);
    for (uint32_t i = 0; i < UPCASE_UNITS; ++i)
        map_[i] = static_cast<char16_t>(i);
    uint32_t index = 0;
    bool     skip  = false;
    for (size_t i = 0; i + 1 < compressed.size() && index < UPCASE_UNITS; i += 2) {
        const uint16_t v = get16(&compressed[i]);
        if (skip) {
            index += v;
            skip = false;
        } else if (v == 0xFFFF) {
            skip = true;
        } else {
            map_[index++] = static_cast<char16_t>(v);
        }
    }
}

std::u16string UpcaseTable::up(std::u16string_view s) const
{
    std::u16string out(s);
    for (auto& c : out)
        c = map_[c];
    return out;
}

std::u16string utf8_to_utf16(std::string_view s)
{
    std::u16string out;
    size_t         i = 0;
    while (i < s.size()) {
        const auto b0  = static_cast<uint8_t>(s[i]);
        uint32_t   cp  = 0;
        size_t     len = 0;
        if (b0 < 0x80) {
            cp  = b0;
            len = 1;
        } else if ((b0 & 0xE0) == 0xC0) {
            cp  = b0 & 0x1F;
            len = 2;
        } else if ((b0 & 0xF0) == 0xE0) {
            cp  = b0 & 0x0F;
            len = 3;
        } else if ((b0 & 0xF8) == 0xF0) {
            cp  = b0 & 0x07;
            len = 4;
        } else {
            throw std::invalid_argument("invalid UTF-8");
        }
        if (i + len > s.size())
            throw std::invalid_argument("truncated UTF-8");
        for (size_t k = 1; k < len; ++k) {
            const auto b = static_cast<uint8_t>(s[i + k]);
            if ((b & 0xC0) != 0x80)
                throw std::invalid_argument("invalid UTF-8");
            cp = (cp << 6) | (b & 0x3F);
        }
        static constexpr uint32_t MIN_CP[] = {0, 0, 0x80, 0x800, 0x10000};
        if (cp < MIN_CP[len] || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF))
            throw std::invalid_argument("invalid UTF-8 code point");
        if (cp >= 0x10000) {
            cp -= 0x10000;
            out.push_back(static_cast<char16_t>(0xD800 + (cp >> 10)));
            out.push_back(static_cast<char16_t>(0xDC00 + (cp & 0x3FF)));
        } else {
            out.push_back(static_cast<char16_t>(cp));
        }
        i += len;
    }
    return out;
}

std::string utf16_to_utf8(std::u16string_view s)
{
    std::string out;
    for (size_t i = 0; i < s.size(); ++i) {
        uint32_t cp = s[i];
        if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < s.size() && s[i + 1] >= 0xDC00 && s[i + 1] <= 0xDFFF) {
            cp = 0x10000 + ((cp - 0xD800) << 10) + (s[i + 1] - 0xDC00);
            ++i;
        } else if (cp >= 0xD800 && cp <= 0xDFFF) {
            cp = 0xFFFD;
        }
        if (cp < 0x80) {
            out.push_back(static_cast<char>(cp));
        } else if (cp < 0x800) {
            out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else if (cp < 0x10000) {
            out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else {
            out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        }
    }
    return out;
}

bool valid_name(std::u16string_view name)
{
    if (name.empty() || name.size() > MAX_NAME_UNITS || name == u"." || name == u"..")
        return false;
    for (char16_t c : name) {
        if (c < 0x20)
            return false;
        switch (c) {
        case u'"': case u'*': case u'/': case u':': case u'<': case u'>': case u'?': case u'\\': case u'|':
            return false;
        default:
            break;
        }
    }
    return true;
}

Timestamp now_timestamp()
{
    const auto now   = std::chrono::system_clock::now();
    const auto secs  = std::chrono::system_clock::to_time_t(now);
    const auto ms    = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count() % 1000;
    std::tm    tm {};
    gmtime_r(&secs, &tm);
    const int year = std::max(tm.tm_year + 1900, 1980) - 1980;
    Timestamp ts;
    ts.stamp = (static_cast<uint32_t>(year) << 25) | (static_cast<uint32_t>(tm.tm_mon + 1) << 21) |
               (static_cast<uint32_t>(tm.tm_mday) << 16) | (static_cast<uint32_t>(tm.tm_hour) << 11) |
               (static_cast<uint32_t>(tm.tm_min) << 5) | (static_cast<uint32_t>(tm.tm_sec / 2));
    ts.ms10  = static_cast<uint8_t>((tm.tm_sec % 2) * 100 + ms / 10);
    ts.utc   = 0x80;
    return ts;
}

std::vector<std::string> split_path(std::string_view path)
{
    std::vector<std::string> parts;
    size_t                   i = 0;
    while (i <= path.size()) {
        const size_t j = std::min(path.find('/', i), path.size());
        const auto   part = path.substr(i, j - i);
        if (!part.empty() && part != ".")
            parts.emplace_back(part);
        i = j + 1;
    }
    return parts;
}

} // namespace iuv_exfat::fmt
