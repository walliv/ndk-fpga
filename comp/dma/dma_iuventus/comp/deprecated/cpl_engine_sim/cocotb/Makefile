# Makefile: Makefile to compile module
# Copyright 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

TOP_LEVEL_ENT=cpl_engine_sim_wrapper
TARGET=nvc-sim
COCOTB_TEST_MODULES:=cocotb_test
export COCOTB_TEST_MODULES

WAVEFORM_FILE=cpl_engine_sim_wrapper.fst

.PHONY: all see-wave

all: comp

$(WAVEFORM_FILE): all

see-wave: $(WAVEFORM_FILE)
	surfer $< -s waveform.su &

include ../../../../../../build/Makefile
