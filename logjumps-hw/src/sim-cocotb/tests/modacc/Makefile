# Copyright cocotb contributors
# Copyright (c) 2013 Potential Ventures Ltd
# Copyright (c) 2013 SolarFlare Communications Inc
# Licensed under the Revised BSD License, see LICENSE for details.
# SPDX-License-Identifier: BSD-3-Clause

TOPLEVEL_LANG ?= verilog

PWD=$(shell pwd)

# export PYTHONPATH := $(PWD)/../model:$(PYTHONPATH)

ifeq ($(TOPLEVEL_LANG),verilog)
    VERILOG_SOURCES = $(PWD)/../../../rtl/csa_2_pkg.sv $(PWD)/../../../rtl/csa_2.sv $(PWD)/../../../rtl/addtree_pkg.sv $(PWD)/../../../rtl/addtree.sv $(PWD)/../../../rtl/modadd_pkg.sv $(PWD)/../../../rtl/modadd.sv $(PWD)/../../../rtl/modacc_pkg.sv $(PWD)/../../../rtl/modacc.sv 
else ifeq ($(TOPLEVEL_LANG),vhdl)
    $(error This project does not have a VHDL top-level module! TOPLEVEL_LANG=$(TOPLEVEL_LANG))
#     VHDL_SOURCES = $(PWD)/../../rtl/modadd.vhdl
#     ifneq ($(filter $(SIM),ius xcelium),)
#         COMPILE_ARGS += -v93
#     endif
else
    $(error A valid value (verilog or vhdl) was not provided for TOPLEVEL_LANG=$(TOPLEVEL_LANG))
endif

COCOTB_TOPLEVEL     := modacc
COCOTB_TEST_MODULES := test_modacc

include $(shell cocotb-config --makefiles)/Makefile.sim