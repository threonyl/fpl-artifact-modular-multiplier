##################################################################################
## Company: Institute of Information Security, Graz Universtiy of Technology
## Engineer: Florian Hirner and Florian Krieger
##################################################################################

import os, shutil
from config import *
from generate_memory import compare_files
from communication import *

def hbm_ddr_mm_test():
  # write data to the FPGA memory
  write_data_to_hbm_memory()
  write_data_to_ddr_memory()

  # start the FPGA kernel:
  print("##############################################################################")
  if not DEBUG_FLAG:
    ## For Microblaze interaction:
    # print("Waiting for FPGA execution. After FPGA is done, press 'Enter' to continue...")
    # input()

    ## For starting via PCI:
    os.makedirs(os.path.dirname(path_ctrl_files), exist_ok=True)
    print("Start execution on FPGA and wait...")
    startKernelExecution()
    shutil.rmtree(os.path.dirname(path_ctrl_files))

  print("##############################################################################\n")

  # read data from the FPGA memory
  read_data_from_hbm_memory()
  read_data_from_ddr_memory()


def pci_stream_test():
  # start c2h operations:
  for c in range(NUM_PCI_S_CHANNELS):
    read_data_from_fpga_pci_stream(path_bin_output_files + f"pci_{c:02x}_o.bin",c,TRANSFER_BYTES_PCI_S,1,False)

  # start h2c operations:
  for c in range(NUM_PCI_S_CHANNELS):
    write_data_to_fpga_pci_stream(path_bin_input_files + f"pci_{c:02x}_i.bin",c,TRANSFER_BYTES_PCI_S,1,False)
  
  sleep(2) # wait until done


###########################################################################################################################################
# MAIN FUNCTION
###########################################################################################################################################

if __name__ == "__main__":
  print("reload xdma drivers...")
  os.system(XDMA_PATH+"/../tests/reload_driver.sh")

  sleep(2)

  # set up the environment and parameters
  print("Template type: " + TEMPLATE)
  print(f"")
  print(f"Number of DDR Channels       : {NUM_DDR_PCHANNELS}")
  print(f"Number of HBM Channels       : {NUM_HBM_PCHANNELS}")
  print(f"Number of PCI Stream Channels: {NUM_PCI_S_CHANNELS}")
  print(f"")
  print(f"DDR_PCH Memory Size          : {DDR_PCHANNEL_SIZE // (1024 * 1024)} MB")
  print(f"HBM_PCH Memory Size          : {HBM_PCHANNEL_SIZE // (1024 * 1024)} MB")
  print(f"DDR Memory Size              : {DDR_PCHANNEL_SIZE*NUM_DDR_PCHANNELS // (1024 * 1024)} MB")
  print(f"HBM Memory Size              : {HBM_PCHANNEL_SIZE*NUM_HBM_PCHANNELS // (1024 * 1024)} MB")
  print(f"PCI Stream Size              : {TRANSFER_BYTES_PCI_S // (1024 * 1024)} MB")
  print(f"")
  print(f"DDR_WORD_SIZE                : {WORD_SIZE_DDR_BYTES} B -> {WORD_SIZE_DDR_BITS} b")
  print(f"HBM_WORD_SIZE                : {WORD_SIZE_HBM_BYTES} B -> {WORD_SIZE_HBM_BITS} b")
  print(f"PCI_S_WORD_SIZE              : {WORD_SIZE_PCI_S_BYTES} B -> {WORD_SIZE_PCI_S_BITS} b")
  print(f"")


  if TEMPLATE == "HBM_DDR_MM":
    hbm_ddr_mm_test()
  elif TEMPLATE == "PCI_STREAM":
    pci_stream_test()
  else:
    assert False

  

  # check if the data is correct
  print("Do Compare? Y/n")
  if input() != "n":  
    print("Starting comparing files...")

    error = 0

    if TEMPLATE == "HBM_DDR_MM":
      # compare all HBM channels
      for _pch in range(NUM_HBM_PCHANNELS):
        reference_filename = f"./mem/reference/hbm_{_pch:02}_r.bin"
        output_filename    = f"./mem/output/hbm_{_pch:02}_o.bin"
        print(f"  > Comparing hbm_{_pch:02}")
        error |= compare_files(reference_filename, output_filename, WORD_SIZE_HBM_BYTES)

      # compare the DDR result
      for ddr_pch in range(NUM_DDR_PCHANNELS):
        reference_filename = f"./mem/reference/ddr_{ddr_pch:02}_r.bin"
        output_filename    = f"./mem/output/ddr_{ddr_pch:02}_o.bin"
        print(f"  > Comparing ddr_{ddr_pch:02}")
        error |= compare_files(reference_filename, output_filename, WORD_SIZE_DDR_BYTES)

    if TEMPLATE == "PCI_STREAM":
      # compare all PCI stream channels
      for _pch in range(NUM_PCI_S_CHANNELS):
        reference_filename = f"./mem/reference/pci_{_pch:02}_r.bin"
        output_filename    = f"./mem/output/pci_{_pch:02}_o.bin"
        print(f"  > Comparing pci_{_pch:02}")
        error |= compare_files(reference_filename, output_filename, WORD_SIZE_PCI_S_BYTES)

    # print result
    if error:
      print("")
      print("=======================================")
      print("==== THERE ARE ERRORS IN COMPARISON ===")
      print("=======================================\n")
    else:
      print("")
      print("======================")
      print("==== EVERYTHING OK ===")
      print("======================\n")

