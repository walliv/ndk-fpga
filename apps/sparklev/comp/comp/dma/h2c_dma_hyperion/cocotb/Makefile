# Makefile: Makefile to compile module
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0


TOP_LEVEL_ENT=h2c_dma_hyperion
TARGET=nvc-sim
# The nvc flow makes the PSL checks and the abort on an error opt-in; these benches rely on both.
NVC_PSL ?= 1
NVC_EXIT_SEVERITY ?= error

WAVEFORM_FILE=h2c_dma_hyperion.fst
# RAND_SEED=19057233987

.PHONY: all see-wave

all: comp

$(WAVEFORM_FILE): all

see-wave: $(WAVEFORM_FILE)
	surfer $< -s waveform_conf &

include ../../../../../../../build/Makefile