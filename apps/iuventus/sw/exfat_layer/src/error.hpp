// error.hpp: system_error construction shared by the exFAT layer sources
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <string>
#include <system_error>

namespace iuv_exfat {

[[noreturn]] inline void fail(std::errc code, const std::string& msg)
{
    throw std::system_error(std::make_error_code(code), msg);
}

} // namespace iuv_exfat
