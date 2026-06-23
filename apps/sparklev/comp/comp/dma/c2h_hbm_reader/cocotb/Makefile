# Makefile: Makefile to compile module
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

TOP_LEVEL_ENT=c2h_hbm_reader
TARGET=nvc-sim
DEBUG_ENABLE=true
# Exclude vendor-specific IP architectures; empty stubs are compiled instead,
# keeping FIFOX's SH_REG_BASE_DYNAMIC (pure behavioral) as the only bound impl.
NVC_PLATFORM_TAGS = xilinx

WAVEFORM_FILE=c2h_hbm_reader.fst
RAND_SEED=42

.PHONY: all see-wave

all: comp

$(WAVEFORM_FILE): all

see-wave: $(WAVEFORM_FILE)
	surfer $< -s wave_conf &

include ../../../../../../../build/Makefile
