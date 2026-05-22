# Cocotb Makefile for the addtree (binary reduction / CSA tree) testbench

TOPLEVEL_LANG ?= verilog

PWD=$(shell pwd)

ifeq ($(TOPLEVEL_LANG),verilog)
    VERILOG_SOURCES = $(PWD)/../../../rtl/csa_2_pkg.sv \
                      $(PWD)/../../../rtl/csa_2.sv \
                      $(PWD)/../../../rtl/addtree_pkg.sv \
                      $(PWD)/../../../rtl/addtree.sv
else ifeq ($(TOPLEVEL_LANG),vhdl)
    $(error This project does not have a VHDL top-level module! TOPLEVEL_LANG=$(TOPLEVEL_LANG))
else
    $(error A valid value (verilog or vhdl) was not provided for TOPLEVEL_LANG=$(TOPLEVEL_LANG))
endif

COCOTB_TOPLEVEL     := addtree
COCOTB_TEST_MODULES := test_addtree

include $(shell cocotb-config --makefiles)/Makefile.sim