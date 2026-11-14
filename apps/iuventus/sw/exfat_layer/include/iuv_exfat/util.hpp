// util.hpp: integer helpers shared by the exFAT layer, its tools and its tests
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <concepts>
#include <cstdint>
#include <string>

namespace iuv_exfat {

template <std::unsigned_integral T>
constexpr T div_ceil(T a, T b)
{
    return static_cast<T>((a + b - 1) / b);
}

// The whole of s as a number, 0x hex and 0 octal as with strtoull base 0; throws invalid_argument on anything else and
// out_of_range above max.
uint64_t parse_u64(const std::string& s, uint64_t max = UINT64_MAX);

} // namespace iuv_exfat
