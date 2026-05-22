# paths:
path_bin_input_files = "./mem/input/"
path_bin_output_files = "./mem/output/"
path_bin_ref_files = "./mem/reference/"
path_ctrl_files = "./mem/ctrl/"

XDMA_PATH  = "./dma_ip_drivers/XDMA/linux-kernel/tools"
XDMA_XID   = 1         # 0..3

# SELECT TEMPLATE!!!!: #####################################################################################
# TEMPLATE = "HBM_DDR_MM"
TEMPLATE = "PCI_STREAM"
# SELECT TEMPLATE!!!!: #####################################################################################


# memory configuration: #####################################################################################

NUM_DDR_PCHANNELS   = 2
NUM_HBM_PCHANNELS   = 32

WORD_SIZE_DDR_BITS  = 32 # bits
WORD_SIZE_HBM_BITS  = 32 # bits
WORD_SIZE_CSR_BITS  = 32 # bits
WORD_SIZE_DDR_BYTES = WORD_SIZE_DDR_BITS//8
WORD_SIZE_HBM_BYTES = WORD_SIZE_HBM_BITS//8
WORD_SIZE_CSR_BYTES = WORD_SIZE_CSR_BITS//8

TRANSFER_BYTES_DDR  = 1024*1024 # 1MB
TRANSFER_BYTES_HBM  = 1024*1024 # 1MB


# memory address offsets: ###################################################################################

CSR_BASE          = 0x0000_0000_6000_0000

HBM_BASE          = 0x0000_0002_0000_0000
DDR_BASE          = 0x0000_0004_0000_0000

HBM_PCHANNEL_SIZE = 0x0000_0000_1000_0000
DDR_PCHANNEL_SIZE = 0x0000_0004_0000_0000


# pci streaming configuration: ##############################################################################

PCI_S_CONFIG          = "x16" # "x4" or "x16"
NUM_PCI_S_CHANNELS    = 2

WORD_SIZE_PCI_S_BITS  = 256 if PCI_S_CONFIG == "x4" else 512 # bits

WORD_SIZE_PCI_S_BYTES = WORD_SIZE_PCI_S_BITS//8

TRANSFER_BYTES_PCI_S  = 32000 # 128MB

# Debug: ####################################################################################################
DEBUG_FLAG        = False # when set to true, the reference data == input data (no FPGA execution is started)

# scalars for FPGA execution ################################################################################

axi_addr_rtlKernelScalars = [0]*170
# address offset array for scalar registers in FPGA:
# - hbm stack 0
axi_addr_rtlKernelScalars[  4] = 0x00000002 # s0
axi_addr_rtlKernelScalars[  5] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[  6] = 0x00000002 # s1
axi_addr_rtlKernelScalars[  7] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[  8] = 0x00000002 # s2
axi_addr_rtlKernelScalars[  9] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 10] = 0x00000002 # s3
axi_addr_rtlKernelScalars[ 11] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 12] = 0x00000002 # s4
axi_addr_rtlKernelScalars[ 13] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 14] = 0x00000002 # s5
axi_addr_rtlKernelScalars[ 15] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 16] = 0x00000002 # s6
axi_addr_rtlKernelScalars[ 17] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 18] = 0x00000002 # s7
axi_addr_rtlKernelScalars[ 19] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 20] = 0x00000002 # s8
axi_addr_rtlKernelScalars[ 21] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 22] = 0x00000002 # s9
axi_addr_rtlKernelScalars[ 23] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 24] = 0x00000002 # s10
axi_addr_rtlKernelScalars[ 25] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 26] = 0x00000002 # s11
axi_addr_rtlKernelScalars[ 27] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 28] = 0x00000002 # s12
axi_addr_rtlKernelScalars[ 29] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 30] = 0x00000002 # s13
axi_addr_rtlKernelScalars[ 31] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 32] = 0x00000002 # s14
axi_addr_rtlKernelScalars[ 33] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 34] = 0x00000002 # s15
axi_addr_rtlKernelScalars[ 35] = 0x00000000 # -- reserved
# - hbm stack 1
axi_addr_rtlKernelScalars[ 36] = 0x00000002 # s16
axi_addr_rtlKernelScalars[ 37] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 38] = 0x00000002 # s17
axi_addr_rtlKernelScalars[ 39] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 40] = 0x00000002 # s18
axi_addr_rtlKernelScalars[ 41] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 42] = 0x00000002 # s19
axi_addr_rtlKernelScalars[ 43] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 44] = 0x00000002 # s20
axi_addr_rtlKernelScalars[ 45] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 46] = 0x00000002 # s21
axi_addr_rtlKernelScalars[ 47] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 48] = 0x00000002 # s22
axi_addr_rtlKernelScalars[ 49] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 50] = 0x00000002 # s23
axi_addr_rtlKernelScalars[ 51] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 52] = 0x00000002 # s24
axi_addr_rtlKernelScalars[ 53] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 54] = 0x00000002 # s25
axi_addr_rtlKernelScalars[ 55] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 56] = 0x00000002 # s26
axi_addr_rtlKernelScalars[ 57] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 58] = 0x00000002 # s27
axi_addr_rtlKernelScalars[ 59] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 60] = 0x00000002 # s28
axi_addr_rtlKernelScalars[ 61] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 62] = 0x00000002 # s29
axi_addr_rtlKernelScalars[ 63] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 64] = 0x00000002 # s30
axi_addr_rtlKernelScalars[ 65] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 66] = 0x00000002 # s31
axi_addr_rtlKernelScalars[ 67] = 0x00000000 # -- reserved

# pass axi ptrs for memories to rtl kernel
# - hbm stack 0
axi_addr_rtlKernelScalars[ 68] = 0x00000000 # low 		/ ptr00
axi_addr_rtlKernelScalars[ 69] = 0x00000002 # high
axi_addr_rtlKernelScalars[ 70] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 71] = 0x10000000 # low 		/ ptr01
axi_addr_rtlKernelScalars[ 72] = 0x00000002 # high
axi_addr_rtlKernelScalars[ 73] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 74] = 0x20000000 # low 		/ ptr02
axi_addr_rtlKernelScalars[ 75] = 0x00000002 # high
axi_addr_rtlKernelScalars[ 76] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 77] = 0x30000000 # low 		/ ptr03
axi_addr_rtlKernelScalars[ 78] = 0x00000002 # high
axi_addr_rtlKernelScalars[ 79] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 80] = 0x40000000 # low 		/ ptr04
axi_addr_rtlKernelScalars[ 81] = 0x00000002 # high
axi_addr_rtlKernelScalars[ 82] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 83] = 0x50000000 # low 		/ ptr05
axi_addr_rtlKernelScalars[ 84] = 0x00000002 # high
axi_addr_rtlKernelScalars[ 85] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 86] = 0x60000000 # low 		/ ptr06
axi_addr_rtlKernelScalars[ 87] = 0x00000002 # high
axi_addr_rtlKernelScalars[ 88] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 89] = 0x70000000 # low 		/ ptr07
axi_addr_rtlKernelScalars[ 90] = 0x00000002 # high
axi_addr_rtlKernelScalars[ 91] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 92] = 0x80000000 # low 		/ ptr08
axi_addr_rtlKernelScalars[ 93] = 0x00000002 # high
axi_addr_rtlKernelScalars[ 94] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 95] = 0x90000000 # low 		/ ptr09
axi_addr_rtlKernelScalars[ 96] = 0x00000002 # high
axi_addr_rtlKernelScalars[ 97] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[ 98] = 0xA0000000 # low 		/ ptr10
axi_addr_rtlKernelScalars[ 99] = 0x00000002 # high
axi_addr_rtlKernelScalars[100] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[101] = 0xB0000000 # low 		/ ptr11
axi_addr_rtlKernelScalars[102] = 0x00000002 # high
axi_addr_rtlKernelScalars[103] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[104] = 0xC0000000 # low 		/ ptr12
axi_addr_rtlKernelScalars[105] = 0x00000002 # high
axi_addr_rtlKernelScalars[106] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[107] = 0xD0000000 # low 		/ ptr13
axi_addr_rtlKernelScalars[108] = 0x00000002 # high
axi_addr_rtlKernelScalars[109] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[110] = 0xE0000000 # low 		/ ptr14
axi_addr_rtlKernelScalars[111] = 0x00000002 # high
axi_addr_rtlKernelScalars[112] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[113] = 0xF0000000 # low 		/ ptr15
axi_addr_rtlKernelScalars[114] = 0x00000002 # high
axi_addr_rtlKernelScalars[115] = 0x00000000 # -- reserved
# - hbm stack 1
axi_addr_rtlKernelScalars[116] = 0x00000000 # low 		/ ptr16
axi_addr_rtlKernelScalars[117] = 0x00000003 # high
axi_addr_rtlKernelScalars[118] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[119] = 0x10000000 # low 		/ ptr17
axi_addr_rtlKernelScalars[120] = 0x00000003 # high
axi_addr_rtlKernelScalars[121] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[122] = 0x20000000 # low 		/ ptr18
axi_addr_rtlKernelScalars[123] = 0x00000003 # high
axi_addr_rtlKernelScalars[124] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[125] = 0x30000000 # low 		/ ptr19
axi_addr_rtlKernelScalars[126] = 0x00000003 # high
axi_addr_rtlKernelScalars[127] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[128] = 0x40000000 # low 		/ ptr20
axi_addr_rtlKernelScalars[129] = 0x00000003 # high
axi_addr_rtlKernelScalars[130] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[131] = 0x50000000 # low 		/ ptr21
axi_addr_rtlKernelScalars[132] = 0x00000003 # high
axi_addr_rtlKernelScalars[133] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[134] = 0x60000000 # low 		/ ptr22
axi_addr_rtlKernelScalars[135] = 0x00000003 # high
axi_addr_rtlKernelScalars[136] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[137] = 0x70000000 # low 		/ ptr23
axi_addr_rtlKernelScalars[138] = 0x00000003 # high
axi_addr_rtlKernelScalars[139] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[140] = 0x80000000 # low 		/ ptr24
axi_addr_rtlKernelScalars[141] = 0x00000003 # high
axi_addr_rtlKernelScalars[142] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[143] = 0x90000000 # low 		/ ptr25
axi_addr_rtlKernelScalars[144] = 0x00000003 # high
axi_addr_rtlKernelScalars[145] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[146] = 0xA0000000 # low 		/ ptr26
axi_addr_rtlKernelScalars[147] = 0x00000003 # high
axi_addr_rtlKernelScalars[148] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[149] = 0xB0000000 # low 		/ ptr27
axi_addr_rtlKernelScalars[150] = 0x00000003 # high
axi_addr_rtlKernelScalars[151] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[152] = 0xC0000000 # low 		/ ptr28
axi_addr_rtlKernelScalars[153] = 0x00000003 # high
axi_addr_rtlKernelScalars[154] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[155] = 0xD0000000 # low 		/ ptr29
axi_addr_rtlKernelScalars[156] = 0x00000003 # high
axi_addr_rtlKernelScalars[157] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[158] = 0xE0000000 # low 		/ ptr30
axi_addr_rtlKernelScalars[159] = 0x00000003 # high
axi_addr_rtlKernelScalars[160] = 0x00000000 # -- reserved
axi_addr_rtlKernelScalars[161] = 0xF0000000 # low 		/ ptr31
axi_addr_rtlKernelScalars[162] = 0x00000003 # high
axi_addr_rtlKernelScalars[163] = 0x00000000 # -- reserved
# DDR 0
axi_addr_rtlKernelScalars[164] = 0x00000000 # low 		/ ptr32
axi_addr_rtlKernelScalars[165] = 0x00000004 # high
axi_addr_rtlKernelScalars[166] = 0x00000000 # -- reserved
# DDR 1
axi_addr_rtlKernelScalars[167] = 0x00000000 # low 		/ ptr33
axi_addr_rtlKernelScalars[168] = 0x00000008 # high
axi_addr_rtlKernelScalars[169] = 0x00000000 # -- reserved