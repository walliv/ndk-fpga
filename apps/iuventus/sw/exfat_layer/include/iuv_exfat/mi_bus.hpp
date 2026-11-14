// mi_bus.hpp: MI register access to the Iuventus file shell
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <cstdint>
#include <memory>
#include <string>

namespace iuv_exfat {

// Offsets are relative to the file shell's MI base.
class MiBus {
public:
    virtual ~MiBus() = default;

    virtual uint32_t read32(uint64_t offset) = 0;
    virtual void write32(uint64_t offset, uint32_t value) = 0;
};

constexpr const char* FILE_SHELL_COMPATIBLE = "ziti,iuventus_file_shell";

bool nfb_available();
// Throws when built without libnfb.
std::unique_ptr<MiBus> open_nfb_mi_bus(const std::string& dev, const std::string& compatible = FILE_SHELL_COMPATIBLE);

} // namespace iuv_exfat
