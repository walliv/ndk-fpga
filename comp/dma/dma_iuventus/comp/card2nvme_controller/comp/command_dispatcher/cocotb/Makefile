# Makefile: Makefile to compile module
# Copyright (C) 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

TOP_LEVEL_ENT=nvme_cmd_dispatcher
TARGET=nvc-sim

WAVEFORM_FILE=nvme_cmd_dispatcher.fst

.PHONY: all see-wave

all: comp

$(WAVEFORM_FILE): all

see-wave: $(WAVEFORM_FILE)
	surfer $< -s waveform.su &

include ../../../../../../../../../build/Makefile
