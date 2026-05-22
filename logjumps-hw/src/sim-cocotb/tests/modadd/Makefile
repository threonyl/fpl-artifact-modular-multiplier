# Copyright cocotb contributors
# Copyright (c) 2013 Potential Ventures Ltd
# Copyright (c) 2013 SolarFlare Communications Inc
# Licensed under the Revised BSD License, see LICENSE for details.
# SPDX-License-Identifier: BSD-3-Clause

TOPLEVEL_LANG ?= verilog

PWD=$(shell pwd)

# export PYTHONPATH := $(PWD)/../model:$(PYTHONPATH)

ifeq ($(TOPLEVEL_LANG),verilog)
    VERILOG_SOURCES = $(PWD)/../../../rtl/modadd_pkg.sv $(PWD)/../../../rtl/modadd.sv
else ifeq ($(TOPLEVEL_LANG),vhdl)
    $(error This project does not have a VHDL top-level module! TOPLEVEL_LANG=$(TOPLEVEL_LANG))
#     VHDL_SOURCES = $(PWD)/../../rtl/modadd.vhdl
#     ifneq ($(filter $(SIM),ius xcelium),)
#         COMPILE_ARGS += -v93
#     endif
else
    $(error A valid value (verilog or vhdl) was not provided for TOPLEVEL_LANG=$(TOPLEVEL_LANG))
endif

COCOTB_TOPLEVEL     := modadd
COCOTB_TEST_MODULES := test_modadd

include $(shell cocotb-config --makefiles)/Makefile.sim