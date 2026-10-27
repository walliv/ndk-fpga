.. readme.rst: Documentation of single component
.. Copyright (C) 2022 CESNET z. s. p. o.
.. Author(s): Daniel Kondys <kondys@cesnet.cz>
..
.. SPDX-License-Identifier: BSD-3-Clause

.. _mfb_merger_simple_gen:

MFB Merger Simple
-----------------

.. vhdl:autoentity:: MFB_MERGER_SIMPLE

Using MASKING_EN parameter
^^^^^^^^^^^^^^^^^^^^^^^^^^

*True*: Allows switching of ports when reaching EOF in any of the regions regardless if higher
regions within a bus word contain other packets. Therefore, buswords where multiple packets occupy
multiple regions can get split.

*False*: A port switch can happen when reaching an EOF but only if there are no new packets
beginning in that bus word.

For example, in some configurations (like PCIe IPs), a first packet in a bus word can begin only on
byte 0. When masking would be set to true, after a port switch, some packets can begin on higher
bytes other than 0 in a bus word which would break a protocol.

Using ARRIVAL_ORDER_EN parameter
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

*False*: The inputs are served in time slices of
:vhdl:genconstant:`CNT_MAX <mfb_merger_simple.cnt_max>` clock cycles. A frame can leave before a frame of the
other input that was accepted earlier.

*True*: Frames leave in the order the merger accepted them. One input owns the output at a time and only the
owner is accepted; the other input sees DST_RDY low. Ownership passes to the other input after a word of the
owner that leaves no frame open, once the other input has data and the owner either has none or has kept the
output for CNT_MAX clock cycles with TX DST_RDY while the other input had data. A word is never split, so
MASKING_EN has no effect in this mode. The other input waits at most CNT_MAX cycles plus the owner's current
frame.

MFB Merger Simple GEN
---------------------

.. vhdl:autoentity:: MFB_MERGER_SIMPLE_GEN

Using IN_FIFO_DEPTH and STORED_EOF_EN parameters
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

With ``IN_FIFO_DEPTH > 0``, each RX input has an MFB FIFO with this depth in words.

With ``STORED_EOF_EN = True``, the merger starts a packet only when the EOF of this packet is
already in the input FIFO. A started packet then needs no data that are not stored yet.
The merger counts the EOFs in each input FIFO itself.

Use this mode when the RX inputs depend on each other. An example is a source that sends
packets to two mergers through one splitter. A merger that waits in the middle of a packet
can stop this source. The source can then stop the other merger.

The merger masks a SOF only when another RX input has data to send. Without such data, the
merger waits and then sends the held word without a change.

``STORED_EOF_EN = True`` requires ``MASKING_EN = True``. Each input FIFO must hold a packet of
``PKT_SIZE_MAX`` items, so that a full FIFO always contains an EOF.
