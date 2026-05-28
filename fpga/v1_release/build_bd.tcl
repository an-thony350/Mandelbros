
################################################################
# This is a generated script based on design: main_v1
#
# Though there are limitations about the generated script,
# the main purpose of this utility is to make learning
# IP Integrator Tcl commands easier.
################################################################

namespace eval _tcl {
proc get_script_folder {} {
   set script_path [file normalize [info script]]
   set script_folder [file dirname $script_path]
   return $script_folder
}
}
variable script_folder
set script_folder [_tcl::get_script_folder]

################################################################
# Check if script is running in correct Vivado version.
################################################################
set scripts_vivado_version 2023.2
set current_vivado_version [version -short]

if { [string first $scripts_vivado_version $current_vivado_version] == -1 } {
   puts ""
   if { [string compare $scripts_vivado_version $current_vivado_version] > 0 } {
      catch {common::send_gid_msg -ssname BD::TCL -id 2042 -severity "ERROR" " This script was generated using Vivado <$scripts_vivado_version> and is being run in <$current_vivado_version> of Vivado. Sourcing the script failed since it was created with a future version of Vivado."}

   } else {
     catch {common::send_gid_msg -ssname BD::TCL -id 2041 -severity "ERROR" "This script was generated using Vivado <$scripts_vivado_version> and is being run in <$current_vivado_version> of Vivado. Please run the script in Vivado <$scripts_vivado_version> then open the design in Vivado <$current_vivado_version>. Upgrade the design by running \"Tools => Report => Report IP Status...\", then run write_bd_tcl to create an updated script."}

   }

   return 1
}

################################################################
# START
################################################################

# To test this script, run the following commands from Vivado Tcl console:
# source main_v1_script.tcl

# If there is no project opened, this script will create a
# project, but make sure you do not have an existing project
# <./myproj/project_1.xpr> in the current working folder.

set list_projs [get_projects -quiet]
if { $list_projs eq "" } {
   create_project project_1 myproj -part xc7z020clg400-1
}


# CHANGE DESIGN NAME HERE
variable design_name
set design_name main_v1

# If you do not already have an existing IP Integrator design open,
# you can create a design using the following command:
#    create_bd_design $design_name

# Creating design if needed
set errMsg ""
set nRet 0

set cur_design [current_bd_design -quiet]
set list_cells [get_bd_cells -quiet]

if { ${design_name} eq "" } {
   # USE CASES:
   #    1) Design_name not set

   set errMsg "Please set the variable <design_name> to a non-empty value."
   set nRet 1

} elseif { ${cur_design} ne "" && ${list_cells} eq "" } {
   # USE CASES:
   #    2): Current design opened AND is empty AND names same.
   #    3): Current design opened AND is empty AND names diff; design_name NOT in project.
   #    4): Current design opened AND is empty AND names diff; design_name exists in project.

   if { $cur_design ne $design_name } {
      common::send_gid_msg -ssname BD::TCL -id 2001 -severity "INFO" "Changing value of <design_name> from <$design_name> to <$cur_design> since current design is empty."
      set design_name [get_property NAME $cur_design]
   }
   common::send_gid_msg -ssname BD::TCL -id 2002 -severity "INFO" "Constructing design in IPI design <$cur_design>..."

} elseif { ${cur_design} ne "" && $list_cells ne "" && $cur_design eq $design_name } {
   # USE CASES:
   #    5) Current design opened AND has components AND same names.

   set errMsg "Design <$design_name> already exists in your project, please set the variable <design_name> to another value."
   set nRet 1
} elseif { [get_files -quiet ${design_name}.bd] ne "" } {
   # USE CASES: 
   #    6) Current opened design, has components, but diff names, design_name exists in project.
   #    7) No opened design, design_name exists in project.

   set errMsg "Design <$design_name> already exists in your project, please set the variable <design_name> to another value."
   set nRet 2

} else {
   # USE CASES:
   #    8) No opened design, design_name not in project.
   #    9) Current opened design, has components, but diff names, design_name not in project.

   common::send_gid_msg -ssname BD::TCL -id 2003 -severity "INFO" "Currently there is no design <$design_name> in project, so creating one..."

   create_bd_design $design_name

   common::send_gid_msg -ssname BD::TCL -id 2004 -severity "INFO" "Making design <$design_name> as current_bd_design."
   current_bd_design $design_name

}

common::send_gid_msg -ssname BD::TCL -id 2005 -severity "INFO" "Currently the variable <design_name> is equal to \"$design_name\"."

if { $nRet != 0 } {
   catch {common::send_gid_msg -ssname BD::TCL -id 2006 -severity "ERROR" $errMsg}
   return $nRet
}

set bCheckIPsPassed 1
##################################################################
# CHECK IPs
##################################################################
set bCheckIPs 1
if { $bCheckIPs == 1 } {
   set list_check_ips "\ 
xilinx.com:ip:axi_vdma:6.3\
xilinx.com:ip:axis_subset_converter:1.1\
xilinx.com:ip:v_tc:6.2\
xilinx.com:ip:v_axi4s_vid_out:4.0\
xilinx.com:ip:axi_gpio:2.0\
xilinx.com:ip:xlslice:1.0\
xilinx.com:ip:processing_system7:5.5\
xilinx.com:ip:clk_wiz:6.0\
xilinx.com:ip:proc_sys_reset:5.0\
xilinx.com:ip:smartconnect:1.0\
xilinx.com:ip:axis_register_slice:1.1\
xilinx.com:user:packer:1.0\
xilinx.com:user:reorder_buffer:1.0\
xilinx.com:user:iter_core_array:1.0\
xilinx.com:user:pixel_scheduler_top:1.0\
xilinx.com:user:colour_palette:1.0\
xilinx.com:user:perf_counters:1.0\
digilentinc.com:ip:rgb2dvi:1.4\
xilinx.com:ip:xlconcat:2.1\
xilinx.com:ip:xlconstant:1.1\
"

   set list_ips_missing ""
   common::send_gid_msg -ssname BD::TCL -id 2011 -severity "INFO" "Checking if the following IPs exist in the project's IP catalog: $list_check_ips ."

   foreach ip_vlnv $list_check_ips {
      set ip_obj [get_ipdefs -all $ip_vlnv]
      if { $ip_obj eq "" } {
         lappend list_ips_missing $ip_vlnv
      }
   }

   if { $list_ips_missing ne "" } {
      catch {common::send_gid_msg -ssname BD::TCL -id 2012 -severity "ERROR" "The following IPs are not found in the IP Catalog:\n  $list_ips_missing\n\nResolution: Please add the repository containing the IP(s) to the project." }
      set bCheckIPsPassed 0
   }

}

if { $bCheckIPsPassed != 1 } {
  common::send_gid_msg -ssname BD::TCL -id 2023 -severity "WARNING" "Will not continue with creation of design due to the error(s) above."
  return 3
}

##################################################################
# DESIGN PROCs
##################################################################



# Procedure to create entire design; Provide argument to make
# procedure reusable. If parentCell is "", will use root.
proc create_root_design { parentCell } {

  variable script_folder
  variable design_name

  if { $parentCell eq "" } {
     set parentCell [get_bd_cells /]
  }

  # Get object for parentCell
  set parentObj [get_bd_cells $parentCell]
  if { $parentObj == "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2090 -severity "ERROR" "Unable to find parent cell <$parentCell>!"}
     return
  }

  # Make sure parentObj is hier blk
  set parentType [get_property TYPE $parentObj]
  if { $parentType ne "hier" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2091 -severity "ERROR" "Parent <$parentObj> has TYPE = <$parentType>. Expected to be <hier>."}
     return
  }

  # Save current instance; Restore later
  set oldCurInst [current_bd_instance .]

  # Set parent object as current
  current_bd_instance $parentObj


  # Create interface ports
  set TMDS [ create_bd_intf_port -mode Master -vlnv digilentinc.com:interface:tmds_rtl:1.0 TMDS ]


  # Create ports

  # Create instance: axi_vdma_0, and set properties
  set axi_vdma_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_vdma:6.3 axi_vdma_0 ]

  # Create instance: axis_subset_converter_0, and set properties
  set axis_subset_converter_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:axis_subset_converter:1.1 axis_subset_converter_0 ]
  set_property -dict [list \
    CONFIG.M_TDATA_NUM_BYTES {3} \
    CONFIG.S_TDATA_NUM_BYTES {4} \
  ] $axis_subset_converter_0


  # Create instance: v_tc_0, and set properties
  set v_tc_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:v_tc:6.2 v_tc_0 ]
  set_property -dict [list \
    CONFIG.HAS_AXI4_LITE {false} \
    CONFIG.SYNC_EN {false} \
    CONFIG.enable_detection {false} \
  ] $v_tc_0


  # Create instance: v_axi4s_vid_out_0, and set properties
  set v_axi4s_vid_out_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:v_axi4s_vid_out:4.0 v_axi4s_vid_out_0 ]
  set_property -dict [list \
    CONFIG.C_HAS_ASYNC_CLK {1} \
    CONFIG.C_VTG_MASTER_SLAVE {1} \
  ] $v_axi4s_vid_out_0


  # Create instance: axi_gpio_0, and set properties
  set axi_gpio_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_0 ]
  set_property -dict [list \
    CONFIG.C_ALL_INPUTS {1} \
    CONFIG.C_ALL_INPUTS_2 {1} \
    CONFIG.C_IS_DUAL {1} \
  ] $axi_gpio_0


  # Create instance: axi_gpio_1, and set properties
  set axi_gpio_1 [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_1 ]
  set_property -dict [list \
    CONFIG.C_ALL_INPUTS {1} \
    CONFIG.C_ALL_INPUTS_2 {1} \
    CONFIG.C_IS_DUAL {1} \
  ] $axi_gpio_1


  # Create instance: axi_gpio_2, and set properties
  set axi_gpio_2 [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_2 ]
  set_property CONFIG.C_ALL_INPUTS {1} $axi_gpio_2


  # Create instance: xlslice_0, and set properties
  set xlslice_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 xlslice_0 ]
  set_property -dict [list \
    CONFIG.DIN_FROM {31} \
    CONFIG.DIN_WIDTH {64} \
  ] $xlslice_0


  # Create instance: xlslice_1, and set properties
  set xlslice_1 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 xlslice_1 ]
  set_property -dict [list \
    CONFIG.DIN_FROM {63} \
    CONFIG.DIN_TO {32} \
    CONFIG.DIN_WIDTH {64} \
  ] $xlslice_1


  # Create instance: processing_system7_0, and set properties
  set processing_system7_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0 ]
  set_property -dict [list \
    CONFIG.PCW_ACT_APU_PERIPHERAL_FREQMHZ {666.666687} \
    CONFIG.PCW_ACT_CAN_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_DCI_PERIPHERAL_FREQMHZ {10.158730} \
    CONFIG.PCW_ACT_ENET0_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_ENET1_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_FPGA0_PERIPHERAL_FREQMHZ {75.000000} \
    CONFIG.PCW_ACT_FPGA1_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_FPGA2_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_FPGA3_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_PCAP_PERIPHERAL_FREQMHZ {200.000000} \
    CONFIG.PCW_ACT_QSPI_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_SDIO_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_SMC_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_SPI_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_TPIU_PERIPHERAL_FREQMHZ {200.000000} \
    CONFIG.PCW_ACT_TTC0_CLK0_PERIPHERAL_FREQMHZ {111.111115} \
    CONFIG.PCW_ACT_TTC0_CLK1_PERIPHERAL_FREQMHZ {111.111115} \
    CONFIG.PCW_ACT_TTC0_CLK2_PERIPHERAL_FREQMHZ {111.111115} \
    CONFIG.PCW_ACT_TTC1_CLK0_PERIPHERAL_FREQMHZ {111.111115} \
    CONFIG.PCW_ACT_TTC1_CLK1_PERIPHERAL_FREQMHZ {111.111115} \
    CONFIG.PCW_ACT_TTC1_CLK2_PERIPHERAL_FREQMHZ {111.111115} \
    CONFIG.PCW_ACT_UART_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_WDT_PERIPHERAL_FREQMHZ {111.111115} \
    CONFIG.PCW_CLK0_FREQ {75000000} \
    CONFIG.PCW_CLK1_FREQ {10000000} \
    CONFIG.PCW_CLK2_FREQ {10000000} \
    CONFIG.PCW_CLK3_FREQ {10000000} \
    CONFIG.PCW_DDR_RAM_HIGHADDR {0x1FFFFFFF} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {75} \
    CONFIG.PCW_FPGA_FCLK0_ENABLE {1} \
    CONFIG.PCW_UIPARAM_ACT_DDR_FREQ_MHZ {533.333374} \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
  ] $processing_system7_0


  # Create instance: clk_wiz_0, and set properties
  set clk_wiz_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0 ]
  set_property -dict [list \
    CONFIG.CLKOUT1_JITTER {400.680} \
    CONFIG.CLKOUT1_PHASE_ERROR {441.531} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {74.25} \
    CONFIG.CLKOUT2_JITTER {318.319} \
    CONFIG.CLKOUT2_PHASE_ERROR {441.531} \
    CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {371.25} \
    CONFIG.CLKOUT2_USED {true} \
    CONFIG.MMCM_CLKFBOUT_MULT_F {49.500} \
    CONFIG.MMCM_CLKOUT0_DIVIDE_F {10.000} \
    CONFIG.MMCM_CLKOUT1_DIVIDE {2} \
    CONFIG.MMCM_DIVCLK_DIVIDE {5} \
    CONFIG.NUM_OUT_CLKS {2} \
    CONFIG.USE_LOCKED {true} \
    CONFIG.USE_RESET {false} \
  ] $clk_wiz_0


  # Create instance: proc_sys_reset_0, and set properties
  set proc_sys_reset_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0 ]

  # Create instance: proc_sys_reset_1, and set properties
  set proc_sys_reset_1 [ create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_1 ]

  # Create instance: smartconnect_0, and set properties
  set smartconnect_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 smartconnect_0 ]
  set_property -dict [list \
    CONFIG.NUM_MI {6} \
    CONFIG.NUM_SI {1} \
  ] $smartconnect_0


  # Create instance: smartconnect_1, and set properties
  set smartconnect_1 [ create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 smartconnect_1 ]

  # Create instance: axis_register_slice_0, and set properties
  set axis_register_slice_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:axis_register_slice:1.1 axis_register_slice_0 ]
  set_property -dict [list \
    CONFIG.HAS_TKEEP {1} \
    CONFIG.HAS_TLAST {1} \
    CONFIG.HAS_TREADY {1} \
    CONFIG.TDATA_NUM_BYTES {4} \
    CONFIG.TUSER_WIDTH {1} \
  ] $axis_register_slice_0


  # Create instance: packer_0, and set properties
  set packer_0 [ create_bd_cell -type ip -vlnv xilinx.com:user:packer:1.0 packer_0 ]

  # Create instance: reorder_buffer_0, and set properties
  set reorder_buffer_0 [ create_bd_cell -type ip -vlnv xilinx.com:user:reorder_buffer:1.0 reorder_buffer_0 ]
  set_property CONFIG.SEQ_W {20} $reorder_buffer_0


  # Create instance: iter_core_array_0, and set properties
  set iter_core_array_0 [ create_bd_cell -type ip -vlnv xilinx.com:user:iter_core_array:1.0 iter_core_array_0 ]
  set_property CONFIG.SEQ_W {20} $iter_core_array_0


  # Create instance: pixel_scheduler_top_0, and set properties
  set pixel_scheduler_top_0 [ create_bd_cell -type ip -vlnv xilinx.com:user:pixel_scheduler_top:1.0 pixel_scheduler_top_0 ]
  set_property CONFIG.NUM_CORES {16} $pixel_scheduler_top_0


  # Create instance: colour_palette_0, and set properties
  set colour_palette_0 [ create_bd_cell -type ip -vlnv xilinx.com:user:colour_palette:1.0 colour_palette_0 ]

  # Create instance: perf_counters_0, and set properties
  set perf_counters_0 [ create_bd_cell -type ip -vlnv xilinx.com:user:perf_counters:1.0 perf_counters_0 ]

  # Create instance: rgb2dvi_0, and set properties
  set rgb2dvi_0 [ create_bd_cell -type ip -vlnv digilentinc.com:ip:rgb2dvi:1.4 rgb2dvi_0 ]
  set_property -dict [list \
    CONFIG.kClkSwap {false} \
    CONFIG.kGenerateSerialClk {false} \
  ] $rgb2dvi_0


  # Create instance: axi_gpio_3, and set properties
  set axi_gpio_3 [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_3 ]
  set_property CONFIG.C_IS_DUAL {1} $axi_gpio_3


  # Create instance: xlconcat_0, and set properties
  set xlconcat_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_0 ]
  set_property -dict [list \
    CONFIG.IN11_WIDTH {1} \
    CONFIG.IN12_WIDTH {10} \
    CONFIG.IN6_WIDTH {11} \
    CONFIG.IN7_WIDTH {15} \
    CONFIG.NUM_PORTS {8} \
  ] $xlconcat_0


  # Create instance: xlconstant_0, and set properties
  set xlconstant_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 xlconstant_0 ]
  set_property -dict [list \
    CONFIG.CONST_VAL {0} \
    CONFIG.CONST_WIDTH {15} \
  ] $xlconstant_0


  # Create interface connections
  connect_bd_intf_net -intf_net axi_vdma_0_M_AXIS_MM2S [get_bd_intf_pins axi_vdma_0/M_AXIS_MM2S] [get_bd_intf_pins axis_subset_converter_0/S_AXIS]
  connect_bd_intf_net -intf_net axi_vdma_0_M_AXI_MM2S [get_bd_intf_pins axi_vdma_0/M_AXI_MM2S] [get_bd_intf_pins smartconnect_1/S01_AXI]
  connect_bd_intf_net -intf_net axi_vdma_0_M_AXI_S2MM [get_bd_intf_pins smartconnect_1/S00_AXI] [get_bd_intf_pins axi_vdma_0/M_AXI_S2MM]
  connect_bd_intf_net -intf_net axis_register_slice_0_M_AXIS [get_bd_intf_pins axis_register_slice_0/M_AXIS] [get_bd_intf_pins axi_vdma_0/S_AXIS_S2MM]
  connect_bd_intf_net -intf_net axis_subset_converter_0_M_AXIS [get_bd_intf_pins axis_subset_converter_0/M_AXIS] [get_bd_intf_pins v_axi4s_vid_out_0/video_in]
  connect_bd_intf_net -intf_net packer_0_out_stream [get_bd_intf_pins packer_0/out_stream] [get_bd_intf_pins axis_register_slice_0/S_AXIS]
  connect_bd_intf_net -intf_net processing_system7_0_M_AXI_GP0 [get_bd_intf_pins smartconnect_0/S00_AXI] [get_bd_intf_pins processing_system7_0/M_AXI_GP0]
  connect_bd_intf_net -intf_net rgb2dvi_0_TMDS [get_bd_intf_ports TMDS] [get_bd_intf_pins rgb2dvi_0/TMDS]
  connect_bd_intf_net -intf_net smartconnect_0_M00_AXI [get_bd_intf_pins pixel_scheduler_top_0/s00_axi] [get_bd_intf_pins smartconnect_0/M00_AXI]
  connect_bd_intf_net -intf_net smartconnect_0_M01_AXI [get_bd_intf_pins smartconnect_0/M01_AXI] [get_bd_intf_pins axi_vdma_0/S_AXI_LITE]
  connect_bd_intf_net -intf_net smartconnect_0_M02_AXI [get_bd_intf_pins smartconnect_0/M02_AXI] [get_bd_intf_pins axi_gpio_0/S_AXI]
  connect_bd_intf_net -intf_net smartconnect_0_M03_AXI [get_bd_intf_pins smartconnect_0/M03_AXI] [get_bd_intf_pins axi_gpio_1/S_AXI]
  connect_bd_intf_net -intf_net smartconnect_0_M04_AXI [get_bd_intf_pins smartconnect_0/M04_AXI] [get_bd_intf_pins axi_gpio_2/S_AXI]
  connect_bd_intf_net -intf_net smartconnect_0_M05_AXI [get_bd_intf_pins axi_gpio_3/S_AXI] [get_bd_intf_pins smartconnect_0/M05_AXI]
  connect_bd_intf_net -intf_net smartconnect_1_M00_AXI [get_bd_intf_pins processing_system7_0/S_AXI_HP0] [get_bd_intf_pins smartconnect_1/M00_AXI]
  connect_bd_intf_net -intf_net v_axi4s_vid_out_0_vid_io_out [get_bd_intf_pins v_axi4s_vid_out_0/vid_io_out] [get_bd_intf_pins rgb2dvi_0/RGB]
  connect_bd_intf_net -intf_net v_tc_0_vtiming_out [get_bd_intf_pins v_tc_0/vtiming_out] [get_bd_intf_pins v_axi4s_vid_out_0/vtiming_in]

  # Create port connections
  connect_bd_net -net Net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins v_axi4s_vid_out_0/aclk] [get_bd_pins axis_subset_converter_0/aclk] [get_bd_pins axi_vdma_0/m_axis_mm2s_aclk] [get_bd_pins proc_sys_reset_1/slowest_sync_clk] [get_bd_pins v_tc_0/clk] [get_bd_pins v_axi4s_vid_out_0/vid_io_out_clk] [get_bd_pins rgb2dvi_0/PixelClk]
  connect_bd_net -net clk_wiz_0_clk_out2 [get_bd_pins clk_wiz_0/clk_out2] [get_bd_pins rgb2dvi_0/SerialClk]
  connect_bd_net -net clk_wiz_0_locked [get_bd_pins clk_wiz_0/locked] [get_bd_pins proc_sys_reset_1/dcm_locked] [get_bd_pins xlconcat_0/In0]
  connect_bd_net -net colour_palette_0_out_b [get_bd_pins colour_palette_0/out_b] [get_bd_pins packer_0/b]
  connect_bd_net -net colour_palette_0_out_eol [get_bd_pins colour_palette_0/out_eol] [get_bd_pins packer_0/eol]
  connect_bd_net -net colour_palette_0_out_g [get_bd_pins colour_palette_0/out_g] [get_bd_pins packer_0/g]
  connect_bd_net -net colour_palette_0_out_r [get_bd_pins colour_palette_0/out_r] [get_bd_pins packer_0/r]
  connect_bd_net -net colour_palette_0_out_sof [get_bd_pins colour_palette_0/out_sof] [get_bd_pins packer_0/sof] [get_bd_pins perf_counters_0/sof_pulse]
  connect_bd_net -net colour_palette_0_out_valid [get_bd_pins colour_palette_0/out_valid] [get_bd_pins packer_0/valid]
  connect_bd_net -net colour_palette_0_palette_ready [get_bd_pins colour_palette_0/palette_ready] [get_bd_pins perf_counters_0/stream_ready] [get_bd_pins reorder_buffer_0/palette_ready]
  connect_bd_net -net iter_core_array_0_in_ready [get_bd_pins iter_core_array_0/in_ready] [get_bd_pins pixel_scheduler_top_0/in_ready]
  connect_bd_net -net iter_core_array_0_out_escaped [get_bd_pins iter_core_array_0/out_escaped] [get_bd_pins reorder_buffer_0/in_escaped]
  connect_bd_net -net iter_core_array_0_out_iter [get_bd_pins iter_core_array_0/out_iter] [get_bd_pins reorder_buffer_0/in_iter_count]
  connect_bd_net -net iter_core_array_0_out_overflow [get_bd_pins iter_core_array_0/out_overflow] [get_bd_pins reorder_buffer_0/in_overflow]
  connect_bd_net -net iter_core_array_0_out_seq [get_bd_pins iter_core_array_0/out_seq] [get_bd_pins reorder_buffer_0/in_seq_num]
  connect_bd_net -net iter_core_array_0_out_valid [get_bd_pins iter_core_array_0/out_valid] [get_bd_pins reorder_buffer_0/in_valid]
  connect_bd_net -net iter_core_array_0_out_z_i [get_bd_pins iter_core_array_0/out_z_i] [get_bd_pins reorder_buffer_0/in_z_i]
  connect_bd_net -net iter_core_array_0_out_z_r [get_bd_pins iter_core_array_0/out_z_r] [get_bd_pins reorder_buffer_0/in_z_r]
  connect_bd_net -net packer_0_in_stream_ready [get_bd_pins packer_0/in_stream_ready] [get_bd_pins colour_palette_0/out_ready]
  connect_bd_net -net perf_counters_0_snap_frame_cycles [get_bd_pins perf_counters_0/snap_frame_cycles] [get_bd_pins axi_gpio_2/gpio_io_i]
  connect_bd_net -net perf_counters_0_snap_pixels_escaped [get_bd_pins perf_counters_0/snap_pixels_escaped] [get_bd_pins axi_gpio_0/gpio_io_i]
  connect_bd_net -net perf_counters_0_snap_pixels_hit_max [get_bd_pins perf_counters_0/snap_pixels_hit_max] [get_bd_pins axi_gpio_0/gpio2_io_i]
  connect_bd_net -net perf_counters_0_snap_total_iters [get_bd_pins perf_counters_0/snap_total_iters] [get_bd_pins xlslice_1/Din] [get_bd_pins xlslice_0/Din]
  connect_bd_net -net pixel_scheduler_top_0_c_i [get_bd_pins pixel_scheduler_top_0/c_i] [get_bd_pins iter_core_array_0/c_i]
  connect_bd_net -net pixel_scheduler_top_0_c_r [get_bd_pins pixel_scheduler_top_0/c_r] [get_bd_pins iter_core_array_0/c_r]
  connect_bd_net -net pixel_scheduler_top_0_in_valid [get_bd_pins pixel_scheduler_top_0/in_valid] [get_bd_pins iter_core_array_0/in_valid]
  connect_bd_net -net pixel_scheduler_top_0_out_max_iter [get_bd_pins pixel_scheduler_top_0/out_max_iter] [get_bd_pins iter_core_array_0/in_max_iter]
  connect_bd_net -net pixel_scheduler_top_0_out_mode [get_bd_pins pixel_scheduler_top_0/out_mode] [get_bd_pins iter_core_array_0/in_mode]
  connect_bd_net -net pixel_scheduler_top_0_out_seq [get_bd_pins pixel_scheduler_top_0/out_seq] [get_bd_pins iter_core_array_0/in_seq]
  connect_bd_net -net pixel_scheduler_top_0_z0_i [get_bd_pins pixel_scheduler_top_0/z0_i] [get_bd_pins iter_core_array_0/z0_i]
  connect_bd_net -net pixel_scheduler_top_0_z0_r [get_bd_pins pixel_scheduler_top_0/z0_r] [get_bd_pins iter_core_array_0/z0_r]
  connect_bd_net -net proc_sys_reset_0_peripheral_aresetn [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins smartconnect_0/aresetn] [get_bd_pins axis_register_slice_0/aresetn] [get_bd_pins axi_vdma_0/axi_resetn] [get_bd_pins smartconnect_1/aresetn] [get_bd_pins axi_gpio_1/s_axi_aresetn] [get_bd_pins axi_gpio_2/s_axi_aresetn] [get_bd_pins axi_gpio_0/s_axi_aresetn] [get_bd_pins iter_core_array_0/rst_n] [get_bd_pins packer_0/aresetn] [get_bd_pins perf_counters_0/rst_n] [get_bd_pins axi_gpio_3/s_axi_aresetn] [get_bd_pins pixel_scheduler_top_0/s00_axi_aresetn] [get_bd_pins colour_palette_0/rst_n] [get_bd_pins reorder_buffer_0/rst_n]
  connect_bd_net -net proc_sys_reset_1_peripheral_aresetn [get_bd_pins proc_sys_reset_1/peripheral_aresetn] [get_bd_pins axis_subset_converter_0/aresetn] [get_bd_pins v_tc_0/resetn] [get_bd_pins v_axi4s_vid_out_0/aresetn]
  connect_bd_net -net proc_sys_reset_1_peripheral_reset [get_bd_pins proc_sys_reset_1/peripheral_reset] [get_bd_pins v_axi4s_vid_out_0/vid_io_out_reset] [get_bd_pins rgb2dvi_0/aRst]
  connect_bd_net -net processing_system7_0_FCLK_CLK0 [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins processing_system7_0/M_AXI_GP0_ACLK] [get_bd_pins processing_system7_0/S_AXI_HP0_ACLK] [get_bd_pins clk_wiz_0/clk_in1] [get_bd_pins proc_sys_reset_0/slowest_sync_clk] [get_bd_pins smartconnect_0/aclk] [get_bd_pins smartconnect_1/aclk] [get_bd_pins axis_register_slice_0/aclk] [get_bd_pins axi_vdma_0/s_axi_lite_aclk] [get_bd_pins axi_vdma_0/s_axis_s2mm_aclk] [get_bd_pins axi_vdma_0/m_axi_s2mm_aclk] [get_bd_pins axi_vdma_0/m_axi_mm2s_aclk] [get_bd_pins axi_gpio_0/s_axi_aclk] [get_bd_pins axi_gpio_1/s_axi_aclk] [get_bd_pins axi_gpio_2/s_axi_aclk] [get_bd_pins iter_core_array_0/clk] [get_bd_pins packer_0/aclk] [get_bd_pins perf_counters_0/clk] [get_bd_pins axi_gpio_3/s_axi_aclk] [get_bd_pins pixel_scheduler_top_0/s00_axi_aclk] [get_bd_pins colour_palette_0/clk] [get_bd_pins reorder_buffer_0/clk]
  connect_bd_net -net processing_system7_0_FCLK_RESET0_N [get_bd_pins processing_system7_0/FCLK_RESET0_N] [get_bd_pins proc_sys_reset_0/ext_reset_in] [get_bd_pins proc_sys_reset_1/ext_reset_in]
  connect_bd_net -net reorder_buffer_0_out_eol [get_bd_pins reorder_buffer_0/out_eol] [get_bd_pins colour_palette_0/in_eol]
  connect_bd_net -net reorder_buffer_0_out_escaped [get_bd_pins reorder_buffer_0/out_escaped] [get_bd_pins perf_counters_0/pixel_escaped] [get_bd_pins colour_palette_0/in_escaped]
  connect_bd_net -net reorder_buffer_0_out_hit_max [get_bd_pins reorder_buffer_0/out_hit_max] [get_bd_pins perf_counters_0/pixel_hit_max]
  connect_bd_net -net reorder_buffer_0_out_iter_count [get_bd_pins reorder_buffer_0/out_iter_count] [get_bd_pins perf_counters_0/pixel_iter] [get_bd_pins colour_palette_0/in_iter_count]
  connect_bd_net -net reorder_buffer_0_out_overflow [get_bd_pins reorder_buffer_0/out_overflow] [get_bd_pins colour_palette_0/in_overflow]
  connect_bd_net -net reorder_buffer_0_out_ready [get_bd_pins reorder_buffer_0/out_ready] [get_bd_pins iter_core_array_0/out_ready]
  connect_bd_net -net reorder_buffer_0_out_seq_num [get_bd_pins reorder_buffer_0/out_seq_num] [get_bd_pins colour_palette_0/in_seq_num]
  connect_bd_net -net reorder_buffer_0_out_sof [get_bd_pins reorder_buffer_0/out_sof] [get_bd_pins colour_palette_0/in_sof]
  connect_bd_net -net reorder_buffer_0_out_valid [get_bd_pins reorder_buffer_0/out_valid] [get_bd_pins perf_counters_0/stream_valid] [get_bd_pins colour_palette_0/in_valid]
  connect_bd_net -net reorder_buffer_0_out_z_i [get_bd_pins reorder_buffer_0/out_z_i] [get_bd_pins colour_palette_0/in_z_i]
  connect_bd_net -net reorder_buffer_0_out_z_r [get_bd_pins reorder_buffer_0/out_z_r] [get_bd_pins colour_palette_0/in_z_r]
  connect_bd_net -net v_axi4s_vid_out_0_fifo_read_level [get_bd_pins v_axi4s_vid_out_0/fifo_read_level] [get_bd_pins xlconcat_0/In6]
  connect_bd_net -net v_axi4s_vid_out_0_locked [get_bd_pins v_axi4s_vid_out_0/locked] [get_bd_pins xlconcat_0/In1]
  connect_bd_net -net v_axi4s_vid_out_0_overflow [get_bd_pins v_axi4s_vid_out_0/overflow] [get_bd_pins xlconcat_0/In3]
  connect_bd_net -net v_axi4s_vid_out_0_sof_state_out [get_bd_pins v_axi4s_vid_out_0/sof_state_out] [get_bd_pins xlconcat_0/In4]
  connect_bd_net -net v_axi4s_vid_out_0_status [get_bd_pins v_axi4s_vid_out_0/status] [get_bd_pins axi_gpio_3/gpio2_io_i]
  connect_bd_net -net v_axi4s_vid_out_0_underflow [get_bd_pins v_axi4s_vid_out_0/underflow] [get_bd_pins xlconcat_0/In2]
  connect_bd_net -net v_axi4s_vid_out_0_vtg_ce [get_bd_pins v_axi4s_vid_out_0/vtg_ce] [get_bd_pins xlconcat_0/In5]
  connect_bd_net -net xlconcat_0_dout [get_bd_pins xlconcat_0/dout] [get_bd_pins axi_gpio_3/gpio_io_i]
  connect_bd_net -net xlconstant_0_dout [get_bd_pins xlconstant_0/dout] [get_bd_pins xlconcat_0/In7]
  connect_bd_net -net xlslice_0_Dout [get_bd_pins xlslice_0/Dout] [get_bd_pins axi_gpio_1/gpio2_io_i]
  connect_bd_net -net xlslice_1_Dout [get_bd_pins xlslice_1/Dout] [get_bd_pins axi_gpio_1/gpio_io_i]

  # Create address segments
  assign_bd_address -offset 0x00000000 -range 0x20000000 -target_address_space [get_bd_addr_spaces axi_vdma_0/Data_MM2S] [get_bd_addr_segs processing_system7_0/S_AXI_HP0/HP0_DDR_LOWOCM] -force
  assign_bd_address -offset 0x00000000 -range 0x20000000 -target_address_space [get_bd_addr_spaces axi_vdma_0/Data_S2MM] [get_bd_addr_segs processing_system7_0/S_AXI_HP0/HP0_DDR_LOWOCM] -force
  assign_bd_address -offset 0x41200000 -range 0x00010000 -target_address_space [get_bd_addr_spaces processing_system7_0/Data] [get_bd_addr_segs axi_gpio_0/S_AXI/Reg] -force
  assign_bd_address -offset 0x41210000 -range 0x00010000 -target_address_space [get_bd_addr_spaces processing_system7_0/Data] [get_bd_addr_segs axi_gpio_1/S_AXI/Reg] -force
  assign_bd_address -offset 0x41220000 -range 0x00010000 -target_address_space [get_bd_addr_spaces processing_system7_0/Data] [get_bd_addr_segs axi_gpio_2/S_AXI/Reg] -force
  assign_bd_address -offset 0x41230000 -range 0x00010000 -target_address_space [get_bd_addr_spaces processing_system7_0/Data] [get_bd_addr_segs axi_gpio_3/S_AXI/Reg] -force
  assign_bd_address -offset 0x43000000 -range 0x00010000 -target_address_space [get_bd_addr_spaces processing_system7_0/Data] [get_bd_addr_segs axi_vdma_0/S_AXI_LITE/Reg] -force
  assign_bd_address -offset 0x40000000 -range 0x00001000 -target_address_space [get_bd_addr_spaces processing_system7_0/Data] [get_bd_addr_segs pixel_scheduler_top_0/s00_axi/reg0] -force


  # Restore current instance
  current_bd_instance $oldCurInst

  validate_bd_design
  save_bd_design
}
# End of create_root_design()


##################################################################
# MAIN FLOW
##################################################################

create_root_design ""
