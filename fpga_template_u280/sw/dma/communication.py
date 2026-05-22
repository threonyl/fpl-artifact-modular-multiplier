##################################################################################
## Company: Institute of Information Security, Graz Universtiy of Technology
## Engineer: Florian Hirner and Florian Krieger
##################################################################################

import os
from config import *
from time import sleep

# python script to interact with alveo fpga via host 

###########################################################################################################################################
# WRITE DATA TO FPGA MEMORY (H2C, memory mapped)
###########################################################################################################################################

# write data from host to fpga memory (H2C, memory mapped)
# use c programm :
#   $XDMA_PATH/dma_to_device 
#       -d /dev/${XDMA_XID}_h2c_${curChannel} \
#       -f data/datafile${i}_4K.bin \
#       -s $transferSz \
#       -a $base_addr \
#       -c $transferCount &

def write_data_to_fpga_memory(data_file, addr_offset, transfer_size, transfer_count):
  """
  Write data from host to FPGA memory (H2C, memory mapped).
  
  Args:
      data_file (str): Path to the data file to be written.
      addr_offset (int): Address offset in FPGA memory.
      transfer_size (int): Size of the transfer in bytes.
      transfer_count (int): Number of transfers.
  """
  cmd = f"{XDMA_PATH}/dma_to_device -d /dev/xdma{XDMA_XID}_h2c_0 -f {data_file} -s {transfer_size} -a {addr_offset} -c {transfer_count}"
  print(f"[EXEC] cmd: " + f"{XDMA_PATH}/dma_to_device -d /dev/xdma{XDMA_XID}_h2c_0 -f {data_file} -s 0x{transfer_size:x} -a 0x{addr_offset:x} -c {transfer_count}")

  # Execute the command
  if os.system(cmd) != 0:
    print("FAIL!")
    exit(-1)

  return

# write to hbm
def write_data_to_hbm_memory():
  for _pch in range(NUM_HBM_PCHANNELS):
    datafile        = path_bin_input_files + f"hbm_{_pch:02}_i.bin"
    addr_offset     = HBM_BASE + (_pch * HBM_PCHANNEL_SIZE)
    transfer_size   = TRANSFER_BYTES_HBM
    transfer_count  = 1
    write_data_to_fpga_memory(datafile, addr_offset, transfer_size, transfer_count)

  print(f"")
  return

# write to ddr
def write_data_to_ddr_memory():
  for _pch in range(NUM_DDR_PCHANNELS):
    datafile        = path_bin_input_files + f"ddr_{_pch:02}_i.bin"
    addr_offset     = DDR_BASE + (_pch * DDR_PCHANNEL_SIZE)
    transfer_size   = TRANSFER_BYTES_DDR
    transfer_count  = 1
    write_data_to_fpga_memory(datafile, addr_offset, transfer_size, transfer_count)

  print(f"")
  return


###########################################################################################################################################
# READ DATA FROM FPGA MEMORY TO HOST (C2H, memory mapped)
###########################################################################################################################################

# read data from fpga memory to host (C2H, memory mapped)
# use c programm:
#   $XDMA_PATH/dma_from_device \
#     -d /dev/${XDMA_XID}_c2h_${curChannel} \
#     -f data/output_datafile${i}_4K.bin \
#     -s $transferSz \
#     -a $base_addr \
#     -c $transferCount &

def read_data_from_fpga_memory(data_file, addr_offset, transfer_size, transfer_count):
  """
  Read data from FPGA memory to host (C2H, memory mapped).
  
  Args:
      data_file (str): Path to the data file.
      addr_offset (int): Address offset in FPGA memory.
      transfer_size (int): Size of the transfer in bytes.
      transfer_count (int): Number of transfers.
  """
  cmd = f"{XDMA_PATH}/dma_from_device -d /dev/xdma{XDMA_XID}_c2h_0 -f {data_file} -s {transfer_size} -a {addr_offset} -c {transfer_count}"
  print(f"[EXEC] cmd: " + f"{XDMA_PATH}/dma_from_device -d /dev/xdma{XDMA_XID}_c2h_0 -f {data_file} -s 0x{transfer_size:x} -a 0x{addr_offset:x} -c {transfer_count}")

  if os.system(cmd) != 0:
    print("FAIL!")
    exit(-1)

  return

# read from hbm
def read_data_from_hbm_memory():
  for _pch in range(NUM_HBM_PCHANNELS):
    datafile        = path_bin_output_files + f"hbm_{_pch:02}_o.bin"
    addr_offset     = HBM_BASE + (_pch * HBM_PCHANNEL_SIZE)
    transfer_size   = TRANSFER_BYTES_HBM
    transfer_count  = 1
    read_data_from_fpga_memory(datafile, addr_offset, transfer_size, transfer_count)

  print(f"")
  return

## read from ddr. This read is performed page-wise
def read_data_from_ddr_memory():
  for _pch in range(NUM_DDR_PCHANNELS):
    datafile        = path_bin_output_files + f"ddr_{_pch:02}_o.bin"
    addr_offset     = DDR_BASE + (_pch * DDR_PCHANNEL_SIZE)
    transfer_size   = TRANSFER_BYTES_DDR
    transfer_count  = 1
    read_data_from_fpga_memory(datafile, addr_offset, transfer_size, transfer_count)

  print(f"")
  return


###########################################################################################################################################
# WRITE DATA TO PCI (H2C, stream)
###########################################################################################################################################

# write data from host to fpga (H2C, stream)
# use c programm :
#   $XDMA_PATH/dma_to_device 
#       -d /dev/${XDMA_XID}_h2c_${curChannel} \
#       -f data/datafile${i}_4K.bin \
#       -s $transferSz \
#       -a $base_addr \
#       -c $transferCount &

def write_data_to_fpga_pci_stream(data_file, channel, transfer_size, transfer_count, block=True):
  """
  Write data from host to FPGA's PCI (H2C, stream).
  
  Args:
      data_file (str): Path to the data file to be written.
      channel (int): PCI channel number (0-3)
      transfer_size (int): Size of the transfer in bytes.
      transfer_count (int): Number of transfers.
      block (bool): block execution until finished.
  """
  cmd = f"{XDMA_PATH}/dma_to_device -d /dev/xdma{XDMA_XID}_h2c_{channel} -f {data_file} -s {transfer_size} -c {transfer_count}"
  if not block:
    cmd += " &"
  print(f"[EXEC] cmd: " + f"{XDMA_PATH}/dma_to_device -d /dev/xdma{XDMA_XID}_h2c_{channel} -f {data_file} -s 0x{transfer_size:x} -c {transfer_count}")

  # Execute the command
  if os.system(cmd) != 0:
    print("FAIL!")
    exit(-1)

  return


###########################################################################################################################################
# READ DATA FROM FPGA's PCI TO HOST (C2H, stream)
###########################################################################################################################################

# read data from fpga's PCI to host (C2H, stream)
# use c programm:
#   $XDMA_PATH/dma_from_device \
#     -d /dev/${XDMA_XID}_c2h_${curChannel} \
#     -f data/output_datafile${i}_4K.bin \
#     -s $transferSz \
#     -a $base_addr \
#     -c $transferCount &

def read_data_from_fpga_pci_stream(data_file, channel, transfer_size, transfer_count, block=True):
  """
  Read data from FPGA memory to host (C2H, stream).
  
  Args:
      data_file (str): Path to the data file.
      channel (int): PCI channel number (0-3).
      transfer_size (int): Size of the transfer in bytes.
      transfer_count (int): Number of transfers.
      block (bool): block execution until finished.
  """
  cmd = f"{XDMA_PATH}/dma_from_device -d /dev/xdma{XDMA_XID}_c2h_{channel} -f {data_file} -s {transfer_size} -c {transfer_count}"
  if not block:
    cmd += " &"
  print(f"[EXEC] cmd: " + f"{XDMA_PATH}/dma_from_device -d /dev/xdma{XDMA_XID}_c2h_{channel} -f {data_file} -s 0x{transfer_size:x} -c {transfer_count}")

  if os.system(cmd) != 0:
    print("FAIL!")
    exit(-1)

  return


###########################################################################################################################################
# START FPGA KERNEL
###########################################################################################################################################
def readCtrlWord():
  
  datafile        = path_ctrl_files + f"ctrl_read.bin"
  addr_offset     = CSR_BASE
  transfer_size   = 4
  transfer_count  = 1
  read_data_from_fpga_memory(datafile, addr_offset, transfer_size, transfer_count)

  with open(datafile, "rb") as f:
    ctrl_word = f.read(transfer_size)
    ctrl_word = int.from_bytes(ctrl_word, 'little')
    print("read ctrl word:", hex(ctrl_word))
    if ctrl_word & (1<<0) != 0: print("  start bit")
    if ctrl_word & (1<<1) != 0: print("  done  bit")
    if ctrl_word & (1<<2) != 0: print("  idle  bit")
    if ctrl_word & (1<<3) != 0: print("  ready bit")
  
  return ctrl_word

def writeScalars(scalar_values):

  print("Writing scalars...")
  datafile        = path_ctrl_files + f"ctrl_scalars.bin"
  addr_offset     = CSR_BASE + 4 * WORD_SIZE_CSR_BYTES # skip the first 4 32-bit (4 bytes) words
  transfer_size   = len(scalar_values) * WORD_SIZE_CSR_BYTES
  transfer_count  = 1

  with open(datafile, "wb") as f:
    for scalar_word in scalar_values:
      f.write(scalar_word.to_bytes(WORD_SIZE_CSR_BYTES, 'little'))

  write_data_to_fpga_memory(datafile, addr_offset, transfer_size, transfer_count)  

def writeCtrlWord(ctrl_word:int):

  print("Write ctrl word:", hex(ctrl_word))
  datafile        = path_ctrl_files + f"ctrl_write.bin"
  addr_offset     = CSR_BASE
  transfer_size   = 4
  transfer_count  = 1

  with open(datafile, "wb") as f:
    f.write(ctrl_word.to_bytes(transfer_size, 'little'))

  write_data_to_fpga_memory(datafile, addr_offset, transfer_size, transfer_count)  

def startKernelExecution():
    
    # write scalars:
    writeScalars(axi_addr_rtlKernelScalars[4:])

    # check idle bit:
    ctrl_word = readCtrlWord()
    if ctrl_word & (1<<2) == 0:
      print("[ERROR] Idle bit is not set!!")
      exit(-1)

    # set start bit:
    writeCtrlWord(1<<0)
    sleep(0.01)

    # wait for done bit:
    print("Wait for done bit...")
    while readCtrlWord() & (1<<1) == 0:
      print("Not done yet...")
      sleep(0.01)
    
    print("Done FPGA execution!")

