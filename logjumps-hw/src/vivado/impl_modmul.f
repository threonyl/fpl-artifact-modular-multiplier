# impl_modmul.f - Source list for modmul OOC build
# Files listed in compilation order (dependencies first).
# Paths are relative to this file's directory.
# Blank lines and # comments are ignored.

# DSP primitives
../rtl/dsp_pkg.sv

# CSA primitives
../rtl/csa_2_pkg.sv
../rtl/csa_2.sv
../rtl/csa_tree_pkg.sv
../rtl/csa_tree.sv

# Addtree
../rtl/addtree_pkg.sv
../rtl/addtree.sv

# Modadd
../rtl/modadd_pkg.sv
../rtl/modadd.sv

# Modacc
../rtl/modacc_pkg.sv
../rtl/modacc.sv

# Integer multiplier hierarchy
../rtl/dsp_mul.sv
../rtl/mac_std_pkg.sv
../rtl/mac_std.sv
../rtl/intmul_nonstd_BBxAB_pkg.sv
../rtl/intmul_nonstd_BBxAB.sv
../rtl/intmul_nonstd_BBAxBBA_pkg.sv
../rtl/intmul_nonstd_BBAxBBA.sv
../rtl/karatsuba_mul_pkg.sv
../rtl/karatsuba_mul.sv
../rtl/intmul_wrapper_pkg.sv
../rtl/intmul_wrapper.sv

# LogJumps reduction
../rtl/logjumps_pkg.sv
../rtl/logjumps.sv

# Top-level: modular multiplication
../rtl/modmul_pkg.sv
../rtl/modmul.sv