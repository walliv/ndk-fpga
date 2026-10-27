# Makefile: cocotb bench of the MFB drivers
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

TOP_LEVEL_ENT=DRIVER_IDLE_TB
TOP_LEVEL_PATH=.
TARGET=cocotb

# The cocotb Python of this bench imports the cocotbext of this repository, which pyproject.toml installs for Questa.
NVC_RUN_ENV = PYTHONPATH=$(OFM_PYTHONPATH):$(CURDIR):$$PYTHONPATH

.PHONY: all
all: comp

include ../../../../build/Makefile
