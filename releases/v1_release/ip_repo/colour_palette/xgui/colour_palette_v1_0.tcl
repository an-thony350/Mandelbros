# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  ipgui::add_param $IPINST -name "ITER_W" -parent ${Page_0}
  ipgui::add_param $IPINST -name "PALETTE_BITS" -parent ${Page_0}
  ipgui::add_param $IPINST -name "SEQ_W" -parent ${Page_0}
  ipgui::add_param $IPINST -name "W" -parent ${Page_0}


}

proc update_PARAM_VALUE.ITER_W { PARAM_VALUE.ITER_W } {
	# Procedure called to update ITER_W when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.ITER_W { PARAM_VALUE.ITER_W } {
	# Procedure called to validate ITER_W
	return true
}

proc update_PARAM_VALUE.PALETTE_BITS { PARAM_VALUE.PALETTE_BITS } {
	# Procedure called to update PALETTE_BITS when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.PALETTE_BITS { PARAM_VALUE.PALETTE_BITS } {
	# Procedure called to validate PALETTE_BITS
	return true
}

proc update_PARAM_VALUE.SEQ_W { PARAM_VALUE.SEQ_W } {
	# Procedure called to update SEQ_W when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.SEQ_W { PARAM_VALUE.SEQ_W } {
	# Procedure called to validate SEQ_W
	return true
}

proc update_PARAM_VALUE.W { PARAM_VALUE.W } {
	# Procedure called to update W when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.W { PARAM_VALUE.W } {
	# Procedure called to validate W
	return true
}


proc update_MODELPARAM_VALUE.W { MODELPARAM_VALUE.W PARAM_VALUE.W } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.W}] ${MODELPARAM_VALUE.W}
}

proc update_MODELPARAM_VALUE.ITER_W { MODELPARAM_VALUE.ITER_W PARAM_VALUE.ITER_W } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.ITER_W}] ${MODELPARAM_VALUE.ITER_W}
}

proc update_MODELPARAM_VALUE.SEQ_W { MODELPARAM_VALUE.SEQ_W PARAM_VALUE.SEQ_W } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.SEQ_W}] ${MODELPARAM_VALUE.SEQ_W}
}

proc update_MODELPARAM_VALUE.PALETTE_BITS { MODELPARAM_VALUE.PALETTE_BITS PARAM_VALUE.PALETTE_BITS } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.PALETTE_BITS}] ${MODELPARAM_VALUE.PALETTE_BITS}
}

