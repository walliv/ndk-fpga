# nvme_queue_entries.py: Definitions of NVMe queue entry structures and some
# status codes in enum types 
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

from cocotbext.ofm.utils import SerializableHeader
from enum import IntEnum

class CQEntry(SerializableHeader):
    items = list(zip(
        ['cmd_specific',
         'rsv1',
         'sqhdbl', 'sq_id',
         'cmd_id', 'phase_tag', 'stat_code', 'stat_code_type', 'rsv2', 'more', 'do_not_retry'],
        [32, 32, 16, 16, 16, 1, 8, 3, 2, 1, 1],
    ))

class CQEStatCodeTypes(IntEnum):
    GENERIC = 0x0
    COMMAND_SPECIFIC = 0x1
    MEDIA_ERROR = 0x2
    VENDOR_SPECIFIC = 0x7

class CQEStatusCodes(IntEnum):
    SUCCESS = 0x0
    INVALID_OPCODE = 0x1
    INVALID_FIELD = 0x2
    COMMAND_ID_CONFLICT = 0x3
    DATA_TRANSFER_ERROR = 0x4
    ABORTED_POWER_LOSS = 0x5
    INTERNAL_DEVICE_ERROR = 0x6
    ABORTED_BY_REQUEST = 0x7
    ABORTED_SQ_DELETION = 0x8
    ABORTED_FAILED_FUSED = 0x9
    ABORTED_MISSING_FUSED = 0xa

class SQEOpCodes(IntEnum):
    FLUSH = 0x00
    WRITE = 0x01
    READ = 0x02

class SQEntry(SerializableHeader):
    items = list(zip(
        # Command Dword 0
        ['opcode',
         'fuse',
         'rsv1',
         'psdt',
         'cmd_id',
        # Command Dword 1
         'nsid',
        # Command Dword 2 and 3
         'rsv2',
        # Command Dword 4 and 5
         'mptr',
        # Command Dword 6 to 9
         'prp1',
         'prp2',
        # Command Dword 10 and 11
         'start_lba',
        # Command Dword 12
         'num_lba',
         'rsv3', 
         'prinfo',
         'fua',
         'lr',
        # Command Dword 13
         'dsm',
         'rsv4',
        # Command Dword 14
         'eilbrt',
        # Command Dword 15
         'elbat',
         'elbatm'],

        # Bit widths of each field
        [8,
         2,
         4,
         2,
         16,

         32,

         64,

         64,

         64,
         64,
         
         64,

         16,
         10,
         4,
         1,
         1,

         8,
         24,

         32,

         16,
         16],
    ))
