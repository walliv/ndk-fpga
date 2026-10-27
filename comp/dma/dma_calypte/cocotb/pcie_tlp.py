# pcie_tlp.py: PCIe RQ parsing and CQ encoding for Xilinx and Intel MFB buses of DMA_CALYPTE
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""Layouts of comp/base/pkg/pcie_meta_pack.vhd and the UVM parsers (pcie_axi/fce.sv hdr_rq_get,
pcie_avst/fce.sv hdr_get, ptr_upd_data_parser). DW i is bytes 4i..4i+3 of a frame, little endian."""

from dataclasses import dataclass, field

from cocotbext.ofm.pcie import CQHeader, CQMfbMeta, RQHeader, RQMfbMeta
from cocotbext.ofm.utils.header import SerializableHeader

# Widths of the META layouts of comp/base/pkg/pcie_meta_pack.vhd.
RQ_META_WIDTH = len(RQMfbMeta())
CQ_META_WIDTH = len(CQMfbMeta())

MPS = 256
PAGE_SIZE = 4096

# Fields of uvm_pcie::request_header in the order its do_compare and pcie_rq_comparer check them.
COMPARED_FIELDS = ("fmt", "pcie_type", "tc", "ido", "ro", "ns", "th", "td", "ep", "at", "length",
                   "data", "requester_id", "tag", "lbe", "fbe", "address", "ph")


class DmaHeader(SerializableHeader):
    """DMA header of a Calypte packet, as the RX DMA writes it to the host and the TX DMA reads it from the CQ."""
    items = [("frame_len", 16), ("frame_ptr", 16), ("vld", 1), ("p2p", 1), ("rsvd", 6), ("meta", 24)]


def is_intel(device):
    return device in ("STRATIX10", "AGILEX")


def encode_fbe(be):
    it = 0
    if be != 0:
        while it < 4 and not (be >> it) & 1:
            it += 1
    return it


def encode_lbe(be):
    it = 4
    if be != 0:
        while it > 0 and not (be >> (it - 1)) & 1:
            it -= 1
    return it


def _bits(val, hi, lo):
    return (val >> lo) & ((1 << (hi - lo + 1)) - 1)


def rq_hdr_address(hdr, device):
    """Byte address of the 128-bit PCIe header of an RQ frame (its META on Intel, its first 4 DWs on AMD)."""
    if is_intel(device):
        dw0, dw2, dw3 = hdr & 0xFFFFFFFF, (hdr >> 64) & 0xFFFFFFFF, (hdr >> 96) & 0xFFFFFFFF
        return ((dw2 << 32) | (dw3 & ~3)) if (dw0 >> 29) & 1 else dw2 & ~3
    return hdr & ((1 << 64) - 1) & ~3


def dws_from_bytes(data):
    """DW list of a frame; a trailing partial DW is zero padded."""
    pad = (-len(data)) % 4
    data = bytes(data) + b"\x00" * pad
    return [int.from_bytes(data[i:i + 4], "little") for i in range(0, len(data), 4)]


@dataclass
class RqTlp:
    """uvm_pcie::request_header. `data` holds DWs; `data_mask` (model side only) holds per-DW
    byte-lane masks of the bits that are compared, the rest is the model's don't care (SV 'x)."""
    fmt: int = 0
    pcie_type: int = 0
    tc: int = 0
    ido: int = 0
    ro: int = 0
    ns: int = 0
    th: int = 0
    td: int = 0
    ep: int = 0
    at: int = 0
    length: int = 0
    data: list = field(default_factory=list)
    requester_id: int = 0
    tag: int = 0
    lbe: int = 0
    fbe: int = 0
    address: int = 0           # DW address, bits [63:2]
    ph: int = 0
    data_mask: list = None
    # Fields that must be zero in the DUT encoding but have no place in request_header.
    reserved: dict = field(default_factory=dict)
    info: str = ""

    def byte_address(self):
        return self.address << 2

    def describe(self):
        data = " ".join(f"{d:08x}" for d in self.data[:8]) + (" ..." if len(self.data) > 8 else "")
        return (f"fmt={self.fmt:03b} type={self.pcie_type:05b} tc={self.tc} attr(ido,ro,ns)=({self.ido},"
                f"{self.ro},{self.ns}) th={self.th} td={self.td} ep={self.ep} at={self.at} "
                f"len={self.length} rid={self.requester_id:#x} tag={self.tag} fbe={self.fbe:04b} "
                f"lbe={self.lbe:04b} addr={self.byte_address():#x} ph={self.ph} data[{len(self.data)}]={data}"
                + (f" {self.info}" if self.info else ""))


def compare_rq(model, dut):
    """Field-by-field comparison as pcie_rq_comparer; returns the names of differing fields."""
    diffs = []
    for name in COMPARED_FIELDS:
        if name == "data":
            if len(model.data) != len(dut.data):
                diffs.append(f"data length model {len(model.data)} dut {len(dut.data)}")
                continue
            masks = model.data_mask or [0xFFFFFFFF] * len(model.data)
            for i, (m, d, mk) in enumerate(zip(model.data, dut.data, masks)):
                if (m ^ d) & mk:
                    diffs.append(f"data DW{i} model {m:08x} dut {d:08x} mask {mk:08x}")
                    break
        elif getattr(model, name) != getattr(dut, name):
            diffs.append(f"{name} model {getattr(model, name):#x} dut {getattr(dut, name):#x}")
    return diffs


def pcie_requirement_errors(tlp):
    """MPS and 4 KiB page crossing check of pcie_rq_comparer / ptr_upd_data_parser, in bytes: the
    SV code compares the DW count against the byte limits, which is four times too lax."""
    errs = []
    size = 4 * len(tlp.data)
    if size > MPS:
        errs.append(f"payload of {size} B exceeds MPS {MPS} B")
    if ((tlp.byte_address() & (PAGE_SIZE - 1)) + size) > PAGE_SIZE:
        errs.append(f"crosses a {PAGE_SIZE} B page: addr {tlp.byte_address():#x} size {size} B")
    return errs


def parse_rq(frame, meta, device):
    """Parses one RQ MFB frame (bytes, meta of its SOF region) into an RqTlp. Malformed encodings
    and nonzero reserved fields are reported in the second return value."""
    errs = []
    dws = dws_from_bytes(frame)
    tlp = RqTlp()
    if not is_intel(device):
        if len(dws) < 4:
            return None, [f"frame of {len(frame)} B is shorter than the 4 DW descriptor"]
        desc = RQHeader.deserialize(dws[0] | (dws[1] << 32) | (dws[2] << 64) | (dws[3] << 96))
        tlp.at = desc.at
        tlp.address = desc.addr
        dword_count = desc.dword_count
        req_type = desc.req_type
        tlp.ep = desc.poisoned_request
        tlp.requester_id = desc.req_id
        tlp.tag = desc.tag
        completer_id = desc.completer_id
        rq_id_en = desc.req_id_en
        tlp.tc = desc.tc
        attr = desc.attr
        ecrc = desc.force_ecrc
        tlp.ido, tlp.ro, tlp.ns = (attr >> 2) & 1, (attr >> 1) & 1, attr & 1
        tlp.length = dword_count & 0x3FF
        tlp.fmt = (0b010 if req_type == 0b0001 else 0b000) | (1 if (tlp.address >> 30) != 0 else 0)
        tlp.pcie_type = 0
        tlp.th = 0
        tlp.ph = 0
        rq_meta = RQMfbMeta.deserialize(meta)
        tlp.fbe = rq_meta.firstBe
        tlp.lbe = rq_meta.lastBe
        # td is compared against the model like the TX parser does with the descriptor's bit 127.
        tlp.td = ecrc
        tlp.data = dws[4:]
        tlp.reserved = {"rq_type!=1": int(req_type != 0b0001), "rq_id_en": rq_id_en,
                        "completer_id": completer_id, "dword_count[10]": dword_count >> 10}
    else:
        hdr = _bits(meta, 127, 0)
        dw0, dw1, dw2, dw3 = (_bits(hdr, 32 * i + 31, 32 * i) for i in range(4))
        tlp.length = _bits(dw0, 9, 0)
        tlp.at = _bits(dw0, 11, 10)
        tlp.ns = _bits(dw0, 12, 12)
        tlp.ro = _bits(dw0, 13, 13)
        tlp.ep = _bits(dw0, 14, 14)
        tlp.td = _bits(dw0, 15, 15)
        tlp.th = _bits(dw0, 16, 16)
        ln = _bits(dw0, 17, 17)
        tlp.ido = _bits(dw0, 18, 18)
        tag8 = _bits(dw0, 19, 19)
        tlp.tc = _bits(dw0, 22, 20)
        tag9 = _bits(dw0, 23, 23)
        tlp.pcie_type = _bits(dw0, 28, 24)
        tlp.fmt = _bits(dw0, 31, 29)
        tlp.fbe = _bits(dw1, 3, 0)
        tlp.lbe = _bits(dw1, 7, 4)
        tlp.tag = _bits(dw1, 15, 8)
        tlp.requester_id = _bits(dw1, 31, 16)
        if tlp.fmt & 1:
            tlp.address = (dw2 << 30) | _bits(dw3, 31, 2)
            tlp.ph = _bits(dw3, 1, 0)
        else:
            tlp.address = _bits(dw2, 31, 2)
            tlp.ph = _bits(dw2, 1, 0)
        if (tlp.fmt << 5 | tlp.pcie_type) not in (0b01100000, 0b01000000):
            errs.append(f"unsupported request fmt {tlp.fmt:03b} type {tlp.pcie_type:05b}")
        tlp.reserved = {"tag9": tag9, "tag8": tag8, "ln": ln}
        length = tlp.length if tlp.length != 0 else 1024
        if tlp.fmt >> 1 == 0b01:
            # uvm_pcie_avst::hdr_get accepts up to one region (8 DWs) of padding behind the payload.
            if not (length <= len(dws) <= length + 8):
                errs.append(f"payload of {len(dws)} DWs outside [{length}, {length + 8}]")
            tlp.data = dws[:length]
        else:
            tlp.data = []
    for name, val in tlp.reserved.items():
        if val:
            errs.append(f"field {name} is {val:#x}, must be 0")
    return tlp, errs


def mwr_expect(byte_addr, data, ns=0):
    """The MWr request the RX DMA model (dma_model.sv get_pcie_transaction) expects for `data`
    bytes written to `byte_addr`. Bytes behind the payload in the last DW are don't care."""
    assert byte_addr & 3 == 0
    n = len(data)
    lbe = {0: 0b1111, 1: 0b0001, 2: 0b0011, 3: 0b0111}[n % 4]
    tlp = RqTlp(fbe=0b1111, lbe=lbe, ns=ns, address=(byte_addr >> 2) & ((1 << 62) - 1))
    tlp.fmt = 0b010 if (byte_addr >> 32) == 0 else 0b011
    tlp.length = (n + 3) // 4
    tlp.data = dws_from_bytes(data)
    tlp.data_mask = [0xFFFFFFFF] * tlp.length
    if n % 4:
        tlp.data_mask[-1] = (1 << (8 * (n % 4))) - 1
    if tlp.length == 1:
        tlp.fbe &= tlp.lbe
        tlp.lbe = 0
    return tlp


def ptr_upd_expect(byte_addr, hdp, hhp, p2p):
    """The pointer update both UVM ptr_upd models expect: 2 DW MWr, FBE 1111, LBE 0011."""
    tlp = RqTlp(fbe=0b1111, lbe=0b0011, length=2, ns=p2p, address=(byte_addr >> 2) & ((1 << 62) - 1))
    tlp.fmt = 0b010 if (byte_addr >> 32) == 0 else 0b011
    tlp.data = [hdp, hhp]
    tlp.data_mask = [0xFFFFFFFF, 0xFFFFFFFF]
    return tlp


def cq_encode(device, addr, length, fbe, lbe, payload_dws):
    """CQ MWr as the TX UVM driver's create_pcie_req: returns (frame bytes, CQ META int)."""
    if device == "ULTRASCALE":
        desc = CQHeader()
        desc.addr = addr >> 2
        desc.dword_count = length
        desc.req_type = 0b0001
        desc.bar_id = 0b010
        desc.bar_apper = 26
        hdr = desc.serialize()
        cq_meta = CQMfbMeta()
        cq_meta.firstBe, cq_meta.lastBe = fbe, lbe
        meta = cq_meta.serialize()
        dws = [_bits(hdr, 32 * i + 31, 32 * i) for i in range(4)] + list(payload_dws)
    else:
        is_4dw = 1 if (addr >> 32) != 0 else 0
        hdr = (length & 0x3FF)
        hdr |= 0b01000000 << 24
        hdr |= is_4dw << 29
        hdr |= fbe << 32
        hdr |= lbe << 36
        if is_4dw:
            hdr |= ((addr >> 32) & 0xFFFFFFFF) << 64
            hdr |= ((addr >> 2) & 0x3FFFFFFF) << 98
        else:
            hdr |= ((addr >> 2) & 0x3FFFFFFF) << 66
        meta = hdr | (0b010 << CQMfbMeta.offsets()["bar"])
        dws = list(payload_dws)
    return b"".join(d.to_bytes(4, "little") for d in dws), meta


def cq_decode(frame, meta, device):
    """The TX DMA model's view of a CQ frame: (byte address, dword count, fbe, lbe, payload DWs)."""
    dws = dws_from_bytes(frame)
    if device == "ULTRASCALE":
        desc = CQHeader.deserialize(dws[0] | (dws[1] << 32) | (dws[2] << 64) | (dws[3] << 96))
        dword_cnt = desc.dword_count
        pcie_addr = (desc.addr << 2) | desc.at
        cq_meta = CQMfbMeta.deserialize(meta)
        fbe = cq_meta.firstBe
        lbe = cq_meta.lastBe if dword_cnt > 1 else fbe
        payload = dws[4:]
    else:
        dword_cnt = _bits(meta, 9, 0)
        if _bits(meta, 29, 29):
            pcie_addr = (_bits(meta, 95, 64) << 32) | _bits(meta, 127, 96)
        else:
            pcie_addr = _bits(meta, 95, 64)
        fbe = _bits(meta, 35, 32)
        lbe = _bits(meta, 39, 36) if dword_cnt > 1 else fbe
        payload = dws
    if dword_cnt == 0:
        dword_cnt = 1024
    return pcie_addr, dword_cnt, fbe, lbe, payload
