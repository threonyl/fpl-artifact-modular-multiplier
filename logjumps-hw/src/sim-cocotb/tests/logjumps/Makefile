# Copyright cocotb contributors
# Copyright (c) 2013 Potential Ventures Ltd
# Copyright (c) 2013 SolarFlare Communications Inc
# Licensed under the Revised BSD License, see LICENSE for details.
# SPDX-License-Identifier: BSD-3-Clause

TOPLEVEL_LANG ?= verilog

PWD=$(shell pwd)

RTL_DIR = $(PWD)/../../../rtl

# export PYTHONPATH := $(PWD)/../model:$(PYTHONPATH)

ifeq ($(TOPLEVEL_LANG),verilog)
    VERILOG_SOURCES = $(foreach f,$(shell cat $(RTL_DIR)/compilation_order.f),$(RTL_DIR)/$(f))
else ifeq ($(TOPLEVEL_LANG),vhdl)
    $(error This project does not have a VHDL top-level module! TOPLEVEL_LANG=$(TOPLEVEL_LANG))
else
    $(error A valid value (verilog or vhdl) was not provided for TOPLEVEL_LANG=$(TOPLEVEL_LANG))
endif

COCOTB_TOPLEVEL     := logjumps
COCOTB_TEST_MODULES := test_logjumps

include $(shell cocotb-config --makefiles)/Makefile.sim