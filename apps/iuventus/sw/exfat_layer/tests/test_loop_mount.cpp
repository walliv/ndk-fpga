// test_loop_mount.cpp: read-only loop mount by the Linux exfat driver of an image the library wrote (needs root)
// Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
// Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
//
// SPDX-License-Identifier: Apache-2.0

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <map>
#include <set>
#include <system_error>

#include <unistd.h>

#include "iuv_exfat/file_shell_model.hpp"
#include "iuv_exfat/job.hpp"
#include "test_util.hpp"

using namespace iuv_exfat;
using namespace iuv_test;
namespace fs = std::filesystem;

namespace {

std::string privilege_prefix()
{
    if (::geteuid() == 0)
        return "";
    if (run_cmd("sudo -n true") == 0)
        return "sudo -n ";
    return "-";
}

std::vector<uint8_t> slurp(const fs::path& p)
{
    std::ifstream f(p, std::ios::binary);
    if (!f)
        throw TestFailure("cannot read through the mount: " + p.string());
    return {std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>()};
}

struct Mount {
    std::string prefix;
    std::string dir;
    bool        mounted = false;
    ~Mount()
    {
        if (mounted)
            run_cmd(prefix + "umount '" + dir + "'");
    }
};

} // namespace

int main()
{
    const std::string prefix = privilege_prefix();
    // IUV_LOOP_PREPARE_ONLY runs everything up to the mount, so the unprivileged part is testable without root.
    const bool prepare_only = std::getenv("IUV_LOOP_PREPARE_ONLY") != nullptr;
    if (prefix == "-" && !prepare_only) {
        std::printf("[test_loop_mount] SKIP: loop mount needs root or passwordless sudo (sudo -n)\n");
        return SKIP;
    }
    return run_test("test_loop_mount", [&](uint64_t seed, TempDir& tmp) {
        std::mt19937_64 rng(seed);
        const std::string image = tmp.file("vol.img");
        make_image(image, 256 * MIB);
        Files files;
        std::set<std::string> dirs {""};
        {
            auto vol = open_volume(image);
            std::vector<std::string> dir_list {""};
            for (int i = 0; i < 6; ++i) {
                const std::string p = dir_list[rng() % dir_list.size()] + "/" + random_name(rng, 16);
                if (throws_errc(std::errc::file_exists, [&] { vol->make_directory(p); }))
                    continue;
                dirs.insert(p);
                dir_list.push_back(p);
            }
            for (int i = 0; i < 40; ++i)
                put_file(*vol, "/gap" + std::to_string(i), random_bytes(rng, 1));
            for (int i = 0; i < 40; i += 2)
                vol->remove("/gap" + std::to_string(i));
            vol->commit();
            const uint64_t sizes[] = {0, 1, 511, 512, CLUSTER, 3 * CLUSTER + 9, 6 * CLUSTER};
            for (int i = 0; i < 25; ++i) {
                const uint64_t size = i < 7 ? sizes[i] : rng() % (3 * CLUSTER);
                const std::string p = dir_list[rng() % dir_list.size()] + "/" + random_name(rng);
                auto data = random_bytes(rng, size);
                if (throws_errc(std::errc::file_exists, [&] { put_file(*vol, p, data); }))
                    continue;
                files[p] = std::move(data);
            }
            for (int i = 1; i < 40; i += 2)
                files["/gap" + std::to_string(i)] = {};
            for (auto& [p, d] : files)
                if (p.rfind("/gap", 0) == 0)
                    d = read_file(*vol, p);

            std::vector<std::string> ins;
            std::vector<std::vector<uint8_t>> in_data;
            for (const auto& [p, d] : files)
                if (ins.size() < 4 && d.size() > CLUSTER) {
                    ins.push_back(p);
                    in_data.push_back(d);
                }
            Output out = vol->reserve("/job_output.bin", CLUSTER);
            vol->flush();
            auto model = make_file_shell_model(vol->device());
            JobOptions jo;
            jo.extend_bytes = CLUSTER;
            Job job(*model, *vol, jo);
            const uint64_t fill = 3 * CLUSTER + 64;
            job.add_stream(ins, out, digest_fill_args(fill, 99));
            job.submit();
            CHECK(job.wait().ok);
            vol->commit();
            files["/job_output.bin"] = digest_fill_expected(in_data, fill, 99);
            vol->close();
        }
        check_volume(image, tmp, "before mount");
        if (prepare_only) {
            std::printf("IUV_LOOP_PREPARE_ONLY: image prepared, mount not attempted\n");
            return;
        }

        Mount m {prefix, tmp.file("mnt")};
        fs::create_directories(m.dir);
        std::string out;
        if (run_cmd(prefix + "mount -t exfat -o ro,loop,offset=1048576 '" + image + "' '" + m.dir + "'", &out) != 0)
            throw TestFailure("mount failed: " + out);
        m.mounted = true;
        for (const auto& [p, d] : files)
            CHECK(slurp(m.dir + p) == d);
        for (const auto& dir : dirs) {
            const auto want = children_of(dir, files, dirs);
            std::set<std::string> got;
            for (const auto& e : fs::directory_iterator(m.dir + dir))
                got.insert(e.path().filename().string());
            CHECK(got == want);
        }
        std::printf("loop mount verified %zu files in %zu directories\n", files.size(), dirs.size());
    });
}
