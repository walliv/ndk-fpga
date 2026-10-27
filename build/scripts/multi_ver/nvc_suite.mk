# nvc_suite.mk: make targets of the parallel nvc suite of a cocotb bench (see nvc_suite.py)
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

# A bench includes this file after its default goal and before build/Makefile. SUITE_FILE is its pytest file and
# SUITE_PREFIX names its <PREFIX>_* knobs; the defaults run the combinations of ver_settings.py.
NVC_SUITE_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SUITE_FILE ?= $(NVC_SUITE_DIR)/ver_settings_suite.py
SUITE_PREFIX ?= SUITE

# Always `$(PYTHON) -m pytest`: a bare `pytest` may resolve to an interpreter without xdist or cocotb.
PYTHON ?= python3

CONFIG ?=
TEST ?=
# Shard logs and private library copies; the per-config elaborations stay beside the bench.
SHARD_ROOT ?= $(CURDIR)/shards
SUITE_WORKERS ?= 8
SUITE_REPEAT ?= 1
WALL_CAP_S ?= 600
# Only the suite's recipes get these, so that the other targets of the bench, e.g. the Questa run, keep their
# environment. The cocotbext and ofm of this repository go first, ahead of any editable install pointing elsewhere.
SUITE_ENV = PYTHONPATH=$(OFM_PYTHONPATH):$(CURDIR):$(NVC_SUITE_DIR):$(PYTHONPATH) \
	SUITE_TOP=$(TOP_LEVEL_ENT) SUITE_PREFIX=$(SUITE_PREFIX) SUITE_REPEAT=$(SUITE_REPEAT) WALL_CAP_S=$(WALL_CAP_S) \
	$(SUITE_PREFIX)_SUMMARY=$(SHARD_ROOT)/summary.jsonl WAVES=$(WAVES) NVC_EXIT_SEVERITY=$(NVC_EXIT_SEVERITY) \
	RANDOM_SEED=$(RANDOM_SEED)

CLEAN_DEPENDS += clean_suite

.PHONY: suite suite-analyse suite-run clean_suite

suite: suite-analyse
	$(SUITE_ENV) $(PYTHON) -m pytest -p no:cacheprovider -n $(SUITE_WORKERS) --dist worksteal -v -rA --basetemp=$(SHARD_ROOT) $(SUITE_FILE)

# Analyses the sources once into nvcwork/, which every configuration copies and elaborates on its own.
suite-analyse:
	$(MAKE) TARGET=nvc-elab comp

# The shards of CONFIG and TEST one after another, on the analysis left by suite-analyse.
suite-run:
	$(SUITE_ENV) $(SUITE_PREFIX)_CONFIG_FILTER=$(CONFIG) $(SUITE_PREFIX)_TEST_FILTER=$(TEST) \
		$(PYTHON) -m pytest -p no:cacheprovider -n 0 -v -rA --basetemp=$(SHARD_ROOT) $(SUITE_FILE)

clean_suite:
	-@$(RM) -r elab/ shards/
