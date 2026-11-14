// util.cpp: integer helpers shared by the exFAT layer, its tools and its tests
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#include "iuv_exfat/util.hpp"

#include <cctype>
#include <cerrno>
#include <cstdlib>
#include <stdexcept>

namespace iuv_exfat {

uint64_t parse_u64(const std::string& s, uint64_t max)
{
    // strtoull alone would skip blanks, accept a sign and stop at junk.
    if (s.empty() || !std::isdigit(static_cast<unsigned char>(s[0])))
        throw std::invalid_argument("not a number: '" + s + "'");
    char* end = nullptr;
    errno = 0;
    const unsigned long long v = std::strtoull(s.c_str(), &end, 0);
    if (end != s.c_str() + s.size())
        throw std::invalid_argument("not a number: '" + s + "'");
    if (errno == ERANGE || v > max)
        throw std::out_of_range("'" + s + "' exceeds " + std::to_string(max));
    return v;
}

} // namespace iuv_exfat
