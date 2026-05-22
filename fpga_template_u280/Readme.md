# CryptoCore Template for Alveo U280

This repository contains the hardware and software sources to create U280 designs.

## Configuration and Setup:

Using this code requires:
- Alveo U280 FPGA
- Ubuntu 20.04 GA
- Vivado and Vitis 2022.2
- Python3

## Folder structure
```
root folder
├-- hw/                       All hardware-related files (including Vivado)
│   ├-- ip/                   Vivado-specific IPs used for simulation
│   ├-- proj/                 Folder for Vivado projects
│   │   ├-- vadd_hbm_ddr_mm/  Sub-folders for different configurations 
│   │   └-- vadd_pci_stream/   
│   ├-- rtl/                  Folder containing all rtl files and memory contents. Each project uses some subset of rtl files 
│   │   ├-- vadd_hbm_ddr_mm/  RTL files for testing HBM and DDR with vadd functionality. PCI is used in memory-mapped mode 
│   │   └-- vadd_pci_stream/  RTL files for testing PCI in streaming mode with vadd functionality
│   ├-- scripts/
│   |   └-- *.tcl/            Tcl scripts that build the Vivado project with a given configuration
│   ├-- xdc/                  Contains constraints files (place and route, etc.)
│   └-- xsa/                  Contains hardware specification files (bitstreams) to be flashed onto FPGA
├-- sw/                       All software-related files (including Vitis)
│   ├-- dma/                  Code and scripts for data echange over PCI (card to host and host to card)
│   ├-- microblaze/           Code to run a memory test on the Microblaze CPU (if part of the design) and to interface with the RTL design
|   ├-- py/                   Code for generating test cases (placeholder)
|   └-- vitis/                Contains Vitis template projects and a folder for Vitis workspace (placeholder)
└-- Readme.md
```


## Creating the Vivado Project

To create a Vivado project, follow the steps below. The Vivado project is required for design runs (synth + impl) and behavioral simulation. The projects with 32HBM/2DDR, PCIx4 stream, and PCIx16 stream are ready to use. Other projects may require some adaptions

```
cd hw/proj/
mkdir logjump
cd logjump
source /tools2/Xilinx/Vivado/2022.2/settings64.sh
vivado -source ../../scripts/01_create_project.tcl -tclargs --origin_dir ../
```


## Run the Design on the FPGA (XDMA via PCI)

To run the artifact bitstream you need to first flash the FPGA. You can either use our prepared bitstream or build your own bitstream via the provided tcl scripts ``hw/scripts/01_create_project.tcl``.

The first step is to flash the selected bitstream to the FPGA. This can either be done manually via the Hardware Manager in Vivado our by using our script ``hw/scripts/03_flash_bitstream.tcl``


```
source /tools2/Xilinx/Vivado/2022.2/settings64.sh
vivado -mode batch -source ../../scripts/03_flash_bitstream.tcl -tclargs --origin_dir ../
```

After the FPGA is flashed we can test the artifact via our scripts provided.
Note:
 + FPGA should be in the Vivado state (not Vitis/XRT state).
 + Make sure that the XDMA driver is loaded correctly before continuing.

The test data need to be generated and than send over the pcie to the fpga, this can be done via:

```
cd sw/dma/
python3 generate_memory
sudo python3 main.py
```

The ``main.py`` file will perform all steps to send the data to the FPGA and also to load the results back to the host. After that the script will print if the test was successfull or not.