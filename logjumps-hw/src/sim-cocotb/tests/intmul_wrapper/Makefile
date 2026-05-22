# Cocotb Makefile for intmul_wrapper testbench
#
# Lists only the RTL sources that intmul_wrapper depends on.
# New, unrelated modules added to the project won't be compiled.

TOPLEVEL_LANG ?= verilog

PWD=$(shell pwd)

RTL_DIR = $(PWD)/../../../rtl

# Files required by intmul_wrapper (packages before modules).
# Only these are compiled -- any new, unrelated files added to
# compilation_order.f will be ignored automatically.
REQUIRED_SOURCES = \
    dsp_pkg.sv \
    csa_2_pkg.sv \
    csa_2.sv \
    csa_tree_pkg.sv \
    csa_tree.sv \
    dsp_mul.sv \
    mac_std_pkg.sv \
    mac_std.sv \
    intmul_nonstd_BBxAB_pkg.sv \
    intmul_nonstd_BBxAB.sv \
    intmul_nonstd_BBAxBBA_pkg.sv \
    intmul_nonstd_BBAxBBA.sv \
    karatsuba_mul_pkg.sv \
    karatsuba_mul.sv \
    intmul_wrapper_pkg.sv \
    intmul_wrapper.sv

ifeq ($(TOPLEVEL_LANG),verilog)
    VERILOG_SOURCES = $(foreach f,$(REQUIRED_SOURCES),$(RTL_DIR)/$(f))
else ifeq ($(TOPLEVEL_LANG),vhdl)
    $(error This project does not have a VHDL top-level module! TOPLEVEL_LANG=$(TOPLEVEL_LANG))
else
    $(error A valid value (verilog or vhdl) was not provided for TOPLEVEL_LANG=$(TOPLEVEL_LANG))
endif

COCOTB_TOPLEVEL     := intmul_wrapper
COCOTB_TEST_MODULES := test_intmul_wrapper

include $(shell cocotb-config --makefiles)/Makefile.sim