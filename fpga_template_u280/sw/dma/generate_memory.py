##################################################################################
## Company: Institute of Information Security, Graz Universtiy of Technology
## Engineer: Florian Hirner and Florian Krieger
##################################################################################

# this takes the memory content files (memory_content/*.mem) and transforms them to *.bin files
# it also prepares the reference file

import os
from config import *
from random import randint


def toBinaryFile(src_data, dst_filename, num_bytes, zero_pad = None):
  """
  Write data from host to FPGA memory (H2C).
  
  Args:
      src_data integers: integer array to be written to the file. each element is stored in one memory word or num_bytes bytes
      dst_filename (str): Path to the destination file *.bin.
      num_bytes (int): Bytes per memory word.
      zero_pad (None, "page", or int): None: no padding, "page": pad to multiple of 4096 bytes, int: number of 0-words appended
  """
  with open(dst_filename, "wb") as f_dst:
    bytes_written = 0
    for value in src_data:
      word = value.to_bytes(num_bytes, 'little')
      f_dst.write(word)
      bytes_written += num_bytes
    if zero_pad is None:
      return
    elif zero_pad == "page":
      if bytes_written % 4096 != 0:
        src_line_int = 0
        word = src_line_int.to_bytes(4096 - (bytes_written % 4096), 'little')
        f_dst.write(word)
    else:
      for _ in range(zero_pad):
        src_line_int = 0
        word = src_line_int.to_bytes(num_bytes, 'little')
        f_dst.write(word)

def read_and_print_file(file_name, word_size):
  """Read a binary file and print its content."""
  with open(file_name, "rb") as f:
    data = f.read()
    for i in range(0, len(data), word_size):
      word = data[i:i+word_size]
      print(f"word[{(i//word_size):08d}]: {word.hex()}")
  print("")

def compare_bytes(data1, data2, word_size):
  """ Compares two byte objects and prints status information """
  if data1 == data2 and  len(data1) != 0:
    print("    == SUCCESS data file and ref file are the same! == ")
    return 0
  else:
    print("    == FAIL data file and ref file are different! ==")
  
  if len(data1) != len(data2):
    print("  mismatch in size",len(data1),len(data2))

  ctr = 5

  for i in range(0, min(len(data1),len(data2)), word_size):
    word1 = data1[i:i+word_size]
    word2 = data2[i:i+word_size]
    if word1 != word2:
      print(f"word[{i//word_size}] is incorrect")
      print(word1.hex())
      print(word2.hex())
      ctr -= 1

    if ctr < 0:
      break
  
  return 1

def compare_files(file_name1, file_name2, word_size):
  """Compare two binary files and print differences."""
  with open(file_name1, "rb") as f1, open(file_name2, "rb") as f2:
    data1 = f1.read()
    data2 = f2.read()

    return compare_bytes(data1, data2, word_size)
      


if __name__ == "__main__":
  os.makedirs(os.path.dirname(path_bin_input_files), exist_ok=True)
  os.makedirs(os.path.dirname(path_bin_output_files), exist_ok=True)
  os.makedirs(os.path.dirname(path_bin_ref_files), exist_ok=True)

  # Memory mapped testcases: ######################################################################
  magic_hbm = 0x69000000
  magic_ddr = 0xc3000000

  # Create binary files for HBM (memory mapped):
  for _ in range(NUM_HBM_PCHANNELS):
    input_values = [(magic_hbm | (_<<16) | i) for i in range(TRANSFER_BYTES_HBM//WORD_SIZE_HBM_BYTES)]
    reference_values = [(e + _ + 1 if i < 4096 and not DEBUG_FLAG else e) for i,e in enumerate(input_values)]

    name = f"hbm_{_:02}"
    toBinaryFile(input_values, path_bin_input_files+name+"_i.bin", WORD_SIZE_HBM_BYTES)
    toBinaryFile(reference_values, path_bin_ref_files+name+"_r.bin", WORD_SIZE_HBM_BYTES)
  
  # Create binary file for DDR (memory mapped):
  for _ in range(NUM_DDR_PCHANNELS):
    input_values = [(magic_ddr | (_<<16) | i) for i in range(TRANSFER_BYTES_DDR//WORD_SIZE_DDR_BYTES)]
    reference_values = [(e + _ + 33 if i < 4096 and not DEBUG_FLAG else e) for i,e in enumerate(input_values)]

    name = f"ddr_{_:02}"
    toBinaryFile(input_values, path_bin_input_files+name+"_i.bin", WORD_SIZE_DDR_BYTES)
    toBinaryFile(reference_values, path_bin_ref_files+name+"_r.bin", WORD_SIZE_DDR_BYTES)


  # PCI stream testcases: #########################################################################
  if WORD_SIZE_PCI_S_BITS == 256:
    magic_pci = 0xffeeddccbbaa99887766554433221100_00000000000000000000000000000000 | (randint(0,0xffff) << 16)
  elif WORD_SIZE_PCI_S_BITS == 512:
    magic_pci = 0xffeeddccbbaa99887766554433221100_00000000000000000000000000000000 | (randint(0,0xffff) << 16)
    magic_pci |= 0xfedcba9876543210fedcba9876543210_0123456789abcdef0123456789abcdef << 256
  else:
    assert False # Not implemented yet

  # Create binary files for PCI stream:
  # for _ in range(NUM_PCI_S_CHANNELS):
  #   input_values = [(magic_pci | (_<<16) | i) for i in range(TRANSFER_BYTES_PCI_S//WORD_SIZE_PCI_S_BYTES)]
  #   reference_values = [(e if DEBUG_FLAG else e + _ + 1) for i,e in enumerate(input_values)]

  #   name = f"pci_{_:02}"
  #   toBinaryFile(input_values, path_bin_input_files+name+"_i.bin", WORD_SIZE_PCI_S_BYTES)
  #   toBinaryFile(reference_values, path_bin_ref_files+name+"_r.bin", WORD_SIZE_PCI_S_BYTES)

  input_values_0 = []
  reference_values_0 = []
  input_values_1 = []
  reference_values_1 = []
  with open(f"../../../logjumps-hw/modmul_bls12_381_vectors.txt", "r") as f_in:
    in_lines = f_in.readlines()
    for i in range(TRANSFER_BYTES_PCI_S//WORD_SIZE_PCI_S_BYTES):
      s = in_lines[i].split(" ")
      
      input_values_0 += [int(s[0],16)] # a
      input_values_1 += [int(s[1],16)] # b
      reference_values_0 += [int(s[2],16)]
      reference_values_1 += [0]

  name = f"pci_00"
  toBinaryFile(input_values_0, path_bin_input_files+name+"_i.bin", WORD_SIZE_PCI_S_BYTES)
  toBinaryFile(reference_values_0, path_bin_ref_files+name+"_r.bin", WORD_SIZE_PCI_S_BYTES)
  name = f"pci_01"
  toBinaryFile(input_values_1, path_bin_input_files+name+"_i.bin", WORD_SIZE_PCI_S_BYTES)
  toBinaryFile(reference_values_1, path_bin_ref_files+name+"_r.bin", WORD_SIZE_PCI_S_BYTES)