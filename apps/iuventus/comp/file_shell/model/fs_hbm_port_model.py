# fs_hbm_port_model.py: reference model of FS_HBM_PORT (memory image, MI fence, AXI mapping)
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""What every client must observe: MI writes land at their byte lanes, an MI read returns the word
after every earlier MI write, a fetcher burst returns the image's beats in its own request order,
and RING_WR_PENDING tracks accepted writes without a B response. A client reset aborts what the clients
were waiting for, not the AXI transactions: those finish, their responses are dropped, and the port
takes no request until none is left."""

from collections import deque

from fs_ctx import AXI_BEAT, merge_be


class HbmPortModel:
    def __init__(self, fetchers, hbm_base=0):
        self.fetchers = fetchers
        self.mi_id = fetchers
        self.hbm_base = hbm_base
        self.image = {}             # 32-bit word address -> value, as the MI client wrote it
        self.written = set()
        self.pending = 0            # MI writes accepted, B not yet seen
        self.rd_out = 0             # read bursts whose AR went out, RLAST not yet seen
        self.f_expect = [deque() for _ in range(fetchers)]   # per fetcher: expected (data, last)
        self.mi_read_addr = None

    def preload(self, addr, data):
        for k in range(0, len(data), 4):
            self.image[(addr + k) >> 2] = int.from_bytes(data[k:k + 4], "little")

    def word(self, addr):
        return self.image.get(addr >> 2, 0)

    def beat(self, addr):
        base = addr & ~(AXI_BEAT - 1)
        return b"".join(self.word(base + 4 * k).to_bytes(4, "little") for k in range(AXI_BEAT // 4))

    def mi_write(self, addr, data, be):
        self.image[addr >> 2] = merge_be(self.word(addr), data, be)
        self.written.add(addr >> 2)
        self.pending += 1
        return self.axi_addr(addr), be << (4 * ((addr >> 2) & 7))

    def mi_read(self, addr):
        assert self.pending == 0, "MI read accepted with writes pending"
        assert self.mi_read_addr is None, "second MI read accepted before the first returned"
        self.mi_read_addr = addr
        return self.axi_addr(addr)

    def mi_read_data(self):
        assert self.mi_read_addr is not None, "MI read data with no MI read outstanding"
        addr, self.mi_read_addr = self.mi_read_addr, None
        return self.word(addr)

    def b_response(self):
        assert self.pending > 0, "B response with no write outstanding"
        self.pending -= 1

    def ar_issued(self):
        self.rd_out += 1

    def r_last(self):
        assert self.rd_out > 0, "last R beat with no read burst outstanding"
        self.rd_out -= 1

    def quiet(self):
        """No AXI transaction accepted so far is left to answer."""
        return self.pending == 0 and self.rd_out == 0

    def abort_clients(self):
        """A client reset: nothing the clients waited for is delivered any more."""
        for q in self.f_expect:
            q.clear()
        self.mi_read_addr = None

    def fetch(self, f, addr, beats):
        """A fetcher burst accepted: its expected beats and the AR fields it must produce."""
        for k in range(beats):
            self.f_expect[f].append((self.beat(addr + k * AXI_BEAT), k == beats - 1))
        return self.axi_addr(addr), f, beats - 1

    def axi_addr(self, addr):
        return self.hbm_base + (addr & ~(AXI_BEAT - 1))
