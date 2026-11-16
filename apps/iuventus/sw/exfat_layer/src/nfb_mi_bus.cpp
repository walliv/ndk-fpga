// nfb_mi_bus.cpp: MI access to the file shell through libnfb
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#include "iuv_exfat/mi_bus.hpp"

#include <stdexcept>

#ifdef IUV_EXFAT_HAVE_NFB
#include <nfb/nfb.h>
#endif

namespace iuv_exfat {

#ifdef IUV_EXFAT_HAVE_NFB

namespace {

class NfbMiBus final : public MiBus {
public:
    NfbMiBus(const std::string& dev, const std::string& compatible)
    {
        dev_ = nfb_open(dev.c_str());
        if (!dev_)
            throw std::runtime_error("nfb_open " + dev + " failed");
        const int node = nfb_comp_find(dev_, compatible.c_str(), 0);
        if (node < 0) {
            nfb_close(dev_);
            throw std::runtime_error("no component '" + compatible + "' in the device tree of " + dev);
        }
        comp_ = nfb_comp_open(dev_, node);
        if (!comp_) {
            nfb_close(dev_);
            throw std::runtime_error("nfb_comp_open '" + compatible + "' failed");
        }
    }

    ~NfbMiBus() override
    {
        nfb_comp_close(comp_);
        nfb_close(dev_);
    }

    uint32_t read32(uint64_t offset) override { return nfb_comp_read32(comp_, static_cast<off_t>(offset)); }
    void write32(uint64_t offset, uint32_t value) override { nfb_comp_write32(comp_, static_cast<off_t>(offset), value); }
    void write(uint64_t offset, const uint32_t* words, size_t count) override
    {
        nfb_comp_write(comp_, words, 4 * count, static_cast<off_t>(offset));
    }

private:
    struct nfb_device* dev_  = nullptr;
    struct nfb_comp*   comp_ = nullptr;
};

} // namespace

bool nfb_available() { return true; }

std::unique_ptr<MiBus> open_nfb_mi_bus(const std::string& dev, const std::string& compatible)
{
    return std::make_unique<NfbMiBus>(dev, compatible);
}

#else

bool nfb_available() { return false; }

std::unique_ptr<MiBus> open_nfb_mi_bus(const std::string&, const std::string&)
{
    throw std::runtime_error("iuv_exfat was built without libnfb");
}

#endif

} // namespace iuv_exfat
