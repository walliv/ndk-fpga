# Makefile: Makefile to compile module
# Copyright (C) 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

TOP_LEVEL_ENT=dbl_updater
TARGET=nvc-sim

WAVEFORM_FILE=dbl_updater.fst

.PHONY: all see-wave

all: comp

$(WAVEFORM_FILE): all

see-wave: $(WAVEFORM_FILE)
	surfer $< -s dbl_upd_wave &

include ../../../../../../build/Makefile
