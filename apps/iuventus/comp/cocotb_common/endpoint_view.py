# endpoint_view.py: one endpoint's slice of USER_CORE's per-endpoint port arrays, as a dut stand-in
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

from cocotb.handle import ArrayObject
from cocotb.types import Logic

from cocotbext.ofm.mfb.properties import MFBProperty

# Last value written through a _BitHandle, per vector: cocotb applies only the last write of a
# timestep, so every write must carry the other endpoints' bits as well.
_shadows = {}


class _BitHandle:
    """Bit `idx` of a std_logic_vector port, standing in for a std_logic one. cocotb cannot index a
    packed vector, so a read picks the bit out of the vector and a write goes through _shadows."""

    def __init__(self, vec, idx):
        self._vec = vec
        self._pos = abs(vec.left - idx)
        self._shift = len(vec) - 1 - self._pos
        self._name = f"{vec._name}[{idx}]"
        self._log = vec._log
        # cocotbext.ofm's signal_binstr() samples through handle._handle.
        self._handle = self

    def __len__(self):
        return 1

    def get_signal_val_binstr(self):
        return self._vec._handle.get_signal_val_binstr()[self._pos]

    @property
    def value(self):
        return Logic(self.get_signal_val_binstr())

    @value.setter
    def value(self, val):
        key = self._vec._path
        bits = (_shadows.get(key, 0) & ~(1 << self._shift)) | (int(val) << self._shift)
        _shadows[key] = bits
        self._vec.value = bits


class EndpointView:
    """Endpoint `ep`'s view of the dut: `<group>_<SIG>` names element `ep` of that port array,
    anything else the dut, so MFB drivers and checkers bind to one endpoint by name. Write viewed
    ready bits only through views."""

    def __init__(self, dut, ep, groups=("NVME_RD_MFB",)):
        self._dut = dut
        self._ep = ep
        self._prefixes = tuple(g.upper() + "_" for g in groups)
        self._name = f"{dut._name}_ep{ep}"
        self._log = dut._log
        self._elems = {}

    def __dir__(self):
        return dir(self._dut)

    def __getattr__(self, name):
        if not name.upper().startswith(self._prefixes):
            return getattr(self._dut, name)
        if name not in self._elems:
            arr = getattr(self._dut, name)
            self._elems[name] = arr[self._ep] if isinstance(arr, ArrayObject) else _BitHandle(arr, self._ep)
        return self._elems[name]


def endpoint_views(dut, group="NVME_RD_MFB"):
    """One EndpointView per element of the `group` port arrays."""
    return [EndpointView(dut, ep, (group,)) for ep in range(len(getattr(dut, group + "_SRC_RDY")))]


def attach_endpoint_mfb_properties(dut, clock, group="NVME_RD_MFB", **kwargs):
    """One MFBProperty per endpoint of the `group` port arrays, keyed `group[ep]`. These arrays
    are what attach_mfb_properties() has to be told to exclude."""
    props = {f"{group}[{ep}]": MFBProperty(view, group, clock, label=f"{group}[{ep}]", **kwargs)
             for ep, view in enumerate(endpoint_views(dut, group))}
    dut._log.info("MFB conformance checks on: %s" % ", ".join(props))
    return props
