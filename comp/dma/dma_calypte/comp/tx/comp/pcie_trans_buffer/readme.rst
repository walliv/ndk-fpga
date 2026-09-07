.. _tx_dma_calypte_trans_buffer:

Transaction buffer
==================

.. vhdl:autoentity:: TX_DMA_PCIE_TRANS_BUFFER

Implementation notes
--------------------

Even/odd row banking
^^^^^^^^^^^^^^^^^^^^^

The buffer array is organized as two **row-interleaved banks**: rows (each one whole MFB word wide,
i.e. 64 B for the 2,1,8,32 MFB configuration) with an even index live in bank 0, rows with an odd
index live in bank 1. A barrel-rotated, unaligned write (or read) only ever spans two *neighboring*
rows -- ``row`` and ``row + 1`` -- to bring the wrapped-around bytes back into position, and because
``row`` and ``row + 1`` always fall into different banks, each bank only ever needs a *single* shared
address per access, plus ordinary per-byte write enables. This is what removes the historical
per-DWord/per-byte address plumbing (one address per one of the 64 individual byte lanes) and is also
what makes URAM a legal target for this component (see below).

Each bank is implemented by :ref:`tdp_bram_be` (2-region/TDP configuration, one shared address bus per
port) or by :ref:`sdp_bram` in ``SDP_BRAM_BE`` mode (1-region configuration, independent read/write
address buses, so reads never stall on a concurrent write). Both banks receive the *same* rotated
write data; only the write-enable and the address differ between them. On the read side, both banks
are always fetched for the requested channel/row and the two 512 b words are recombined byte-by-byte
(picking, per byte, whichever bank holds that byte's actual row) before -- optionally -- being
byte-rotated by the read-side barrel shifter to the requested intra-word offset.

Memory primitive selection (:vhdl:genconstant:`RAM_TYPE`)
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

:vhdl:genconstant:`RAM_TYPE` selects the memory primitive used for each bank:

* ``"AUTO"`` (default) resolves to URAM on an AMD UltraScale+/Versal device (:vhdl:genconstant:`DEVICE`)
  when the configuration uses 2 MFB regions and the resulting bank is at least 2048 rows deep
  (avoiding grossly underfilled URAM288 columns); BRAM otherwise.
* ``"BRAM"`` / ``"URAM"`` force the respective primitive; ``"URAM"`` together with an Intel
  :vhdl:genconstant:`DEVICE` fails elaboration (Intel devices always use the structural, per-byte-column
  mapping described in :ref:`tdp_bram_be`).

The maximum usable depth of one memory array (and therefore how many channels share one array,
:vhdl:genconstant:`CHANS_PER_ARRAY`) also depends on the resolved primitive: URAM cascades cheaply to
16384 rows, while BRAM keeps the historical 4096 (AMD) / 2048 (Intel) row limit.

For the default configuration (``CHANNELS => 8``, ``POINTER_WIDTH => 16``, 2 regions, AMD
UltraScale+) this means all 8 channels fit into a *single* URAM-backed array (16 URAM288, 0 BRAM);
forcing ``RAM_TYPE => "BRAM"`` for the same configuration instead splits the channels across 2
BRAM-backed arrays (matching the pre-optimization channel/array split), still fully eliminating the
former per-byte BRAM organization on the control/addressing side.

The historical URAM write-conflict flaw
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

There had been an earlier attempt by a fellow creator of this component to replace the internal RAM
array with URAM for AMD devices, in the previous (per-byte-BRAM) architecture. That attempt failed for
a structural reason: the elementary unit addressable by the PCIe is one DWord, and because of the
internal barrel shifter, a bus beat can contain two DWords -- the first DWord of the beat and the last
DWord of the *previous* row -- that must be written to two *different* rows (this pair is shown in
figure ":ref:`uram_impl_note`", kept for historical reference). A single URAM port has a fixed 8 B
width with no support for splitting one port's access across two different addresses within one
cycle, so one URAM port alone could not serve both rows in the same cycle; with the addressing scheme
used at the time, the DWord meant for the higher address silently overwrote data already stored at the
lower one.

The even/odd row banking implemented here solves this exact problem: the two DWords that need
different row addresses are, by construction, always split across the two banks (``row`` in one bank,
``row + 1`` in the other), so each bank's single shared address is unambiguous and every URAM port only
ever serves one row per cycle. This removed the flaw and is what allows :vhdl:genconstant:`RAM_TYPE`
to legally resolve to URAM.

.. figure:: doc/uram_impl_note.svg
   :width: 100%
   :align: center

   Depiction of the write conflict of the (obsolete) single-bank, per-byte-BRAM URAM attempt

Byte-level access semantics
^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Byte-level *alignment* never requires byte-level *addressing*: PCIe cannot address a lone byte.
:vhdl:portsignal:`PCIE_MFB_META`'s address field is a DWord address and sub-DWord accesses are
expressed exclusively through the per-byte enables (FirstBE/LastBE), e.g. a 64 B write to byte
address ``0x1`` arrives as a 17-DWord transaction at DWord 0 with FBE = ``1110`` and LBE = ``0001``.
Because both write barrel shifters rotate at DWord granularity, a byte never moves between DWord
lanes -- its target row (and therefore its bank) is fully determined by its DWord lane, and the
sub-DWord part is carried purely by the byte-enable bits, which the wide banks natively support.
Consequently a single bus word's write covers at most rows ``row``/``row + 1`` (one address per
bank), for any byte alignment, at line rate.

Two transactions may touch the *same DWord of the same row* in the same cycle (e.g. a 1 B write to
byte ``X`` packed together with a following write starting at byte ``X + 1``): the first arrives on
port A (region 0) and the second on port B (region 1) with **disjoint** byte enables, which is
well-defined on both primitives. Should the two ports ever write the *same byte* (the host rewriting
one location twice within one bus word), URAM resolves it deterministically -- its ports execute
sequentially (A first, then B) within a cycle, so region 1, the later transaction in PCIe order,
wins -- while BRAM leaves that byte undefined, exactly as in the previous per-byte-BRAM
architecture (the simulation-only collision-detect signals flag this case).

Verification
^^^^^^^^^^^^^

The component has a standalone cocotb testbench in ``cocotb/`` (nvc simulator, byte-accurate
reference model in ``trans_buffer_model.py``). It covers aligned/unaligned writes at every DWord
offset with FBE/LBE patterns, dual-SOF words (two frames per bus word to same/different
channels/arrays), channel-buffer wraparound, randomized soak traffic with reads racing the write
stream, and a directed worst case: a 1 B write immediately followed -- with no gap cycle -- by a
64 B write to the next byte address (same DWord touched by both ports, packed dual-SOF and
back-to-back, including a row-straddling base). Run it with::

    cd cocotb
    make                                                    # default generics (AUTO -> URAM)
    NVC_ELAB_ARGS="-gRAM_TYPE=BRAM" make                    # banked-BRAM branch (MEM_ARRAYS > 1)
    NVC_ELAB_ARGS="-gDEVICE=STRATIX10" make                 # Intel structural branch
    NVC_ELAB_ARGS="-gCHANNELS=32 -gPOINTER_WIDTH=13" make   # production DMA Calypte geometry

The ``TB_TXN_GAP`` environment variable (default ``1``) inserts one no-op word between generated
transactions to sidestep a *simulator* artifact of nvc 1.21.0 that affects only the **previous**
(per-byte-BRAM) architecture; set ``TB_TXN_GAP=0`` to drive transactions truly back-to-back at
line rate (the current architecture passes either way).

Resource comparison
^^^^^^^^^^^^^^^^^^^^

Out-of-context synthesis of this entity alone (Vivado 2025.1, xcvu7p, 250 MHz, all timing met):

+----------------------------------------+------------------------------+------------------------------+
| Configuration                          | Previous architecture        | Banked architecture          |
+========================================+==============================+==============================+
| CHANNELS=8, POINTER_WIDTH=16 (default) | 7974 LUT / 3880 FF /         | 7093 LUT / 3299 FF /         |
|                                        | 128 RAMB36                   | 16 URAM, 0 RAMB              |
+----------------------------------------+------------------------------+------------------------------+
| CHANNELS=32, POINTER_WIDTH=13          | 5659 LUT / 3433 FF /         | 6993 LUT / 3277 FF /         |
| (production DMA Calypte)               | 64 RAMB36                    | 16 URAM, 0 RAMB              |
+----------------------------------------+------------------------------+------------------------------+
| default, RAM_TYPE => "BRAM"            | --                           | 8638 LUT / 3320 FF /         |
|                                        |                              | 128 RAMB36                   |
+----------------------------------------+------------------------------+------------------------------+

At the production geometry the URAM variant trades roughly 1.3 k LUTs for freeing all 64 RAMB36
(the URAM columns are then only half-filled); choose per design via :vhdl:genconstant:`RAM_TYPE`.

General subcomponents
---------------------
* :ref:`barrel_shifter`
* :ref:`sdp_bram`

.. _tdp_bram_be:

TDP_BRAM_BE
-----------

.. vhdl:autoentity:: TDP_BRAM_BE

nvc array-demux artifact
------------------------

.. note::

   Simulator defect, not an RTL one; kept here because the testbench works around it.

   NVC_ARRAY_DEMUX_ARTIFACT
   
   Present under nvc 1.21.0 on this exact DUT, MEM_ARRAYS>1 configs only (the default
   CHANNELS=8/POINTER_WIDTH=16 config, MEM_ARRAYS=2).
   
   Two consecutive SOF0-only, fully-byte-enabled (BE=all ones, i.e. an address/DW-aligned first word
   with byte_offset=0 and a payload of >=64 B) write words, whose SOF-carried META_MEM_ARR_IDX bit
   *differs* between them (i.e. their target channels resolve to *different* memory arrays), cause
   the RTL's write_be array-demux (wr_bram_data_demux_p, the "MEM_ARRAYS > 1" generate branch in
   tx_dma_pcie_trans_buffer.vhd) to route the *second* word's data into the *first* word's memory
   array under nvc, silently corrupting a different channel's storage (verified with internal-signal
   probing: mem_arr_idx_next correctly evaluates to the new array index, yet the
   wr_be_bram_demux(<idx>)(0) assignment in the very same process/cycle uses the *old* array index).
   Per VHDL semantics, wr_bram_data_demux_p's "if pcie_mfb_sof_inp_reg(i)='1' then
   wr_be_bram_demux(to_integer(unsigned(pcie_mfb_meta_arr(i)(META_MEM_ARR_IDX))))(i) <= ..." branch
   reads pcie_mfb_meta_arr directly (not a register) and should be correct every cycle regardless of
   write history; the failure only appears under nvc and disappears if any word without a "fully
   enabled" SOF0 (e.g. a no-op/DMA-header word, BE=0) is interposed. This looks like an nvc front-end
   bug resolving a doubly-dynamically-indexed 1-bit slice (`pcie_mfb_meta_arr(i)(META_MEM_ARR_IDX)`,
   itself a single-bit natural-range subtype) used as a `to_integer(unsigned(...))` array index,
   reusing a stale evaluation from an earlier delta. Reproduces identically at -O0 and -O3.
   
   Not worked around by modifying the RTL (out of scope / forbidden by the task). Instead, every
   multi-word helper below inserts one no-op ("DMA header", BE=0) word after each generated
   transaction; empirically this reliably prevents the stale-index reuse. This only matters for the
   MEM_ARRAYS>1 default config; the CHANNELS=32/POINTER_WIDTH=13 config that proves genericity has
   MEM_ARRAYS=1 (see tx_dma_pcie_trans_buffer.vhd's CHANS_PER_ARRAY/MEM_ARRAYS constants) and does
   not instantiate the affected generate branch at all.

