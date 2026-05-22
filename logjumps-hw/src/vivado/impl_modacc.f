# impl_modacc.f - Source list for modacc OOC build
# Files listed in compilation order (dependencies first).
# Paths are relative to this file's directory.
# Blank lines and # comments are ignored.

# CSA primitives
../rtl/csa_2_pkg.sv
../rtl/csa_2.sv

# Addtree
../rtl/addtree_pkg.sv
../rtl/addtree.sv

# Modadd
../rtl/modadd_pkg.sv
../rtl/modadd.sv

# Top-level
../rtl/modacc_pkg.sv
../rtl/modacc.sv

# If you have a wrapper with hardcoded parameters, include it last:
# modacc_wrapper.sv