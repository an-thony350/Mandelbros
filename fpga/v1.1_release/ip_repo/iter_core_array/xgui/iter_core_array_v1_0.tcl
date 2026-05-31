# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  ipgui::add_param $IPINST -name "ESCAPE_THRESH_Q422" -parent ${Page_0}
  ipgui::add_param $IPINST -name "FRAC" -parent ${Page_0}
  ipgui::add_param $IPINST -name "ITER_W" -parent ${Page_0}
  ipgui::add_param $IPINST -name "MODE_W" -parent ${Page_0}
  ipgui::add_param $IPINST -name "NUM_CORES" -parent ${Page_0}
  ipgui::add_param $IPINST -name "SEQ_W" -parent ${Page_0}
  ipgui::add_param $IPINST -name "W" -parent ${Page_0}


}

proc update_PARAM_VALUE.ESCAPE_THRESH_Q422 { PARAM_VALUE.ESCAPE_THRESH_Q422 } {
	# Procedure called to update ESCAPE_THRESH_Q422 when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.ESCAPE_THRESH_Q422 { PARAM_VALUE.ESCAPE_THRESH_Q422 } {
	# Procedure called to validate ESCAPE_THRESH_Q422
	return true
}

proc update_PARAM_VALUE.FRAC { PARAM_VALUE.FRAC } {
	# Procedure called to update FRAC when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.FRAC { PARAM_VALUE.FRAC } {
	# Procedure called to validate FRAC
	return true
}

proc update_PARAM_VALUE.ITER_W { PARAM_VALUE.ITER_W } {
	# Procedure called to update ITER_W when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.ITER_W { PARAM_VALUE.ITER_W } {
	# Procedure called to validate ITER_W
	return true
}

proc update_PARAM_VALUE.MODE_W { PARAM_VALUE.MODE_W } {
	# Procedure called to update MODE_W when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.MODE_W { PARAM_VALUE.MODE_W } {
	# Procedure called to validate MODE_W
	return true
}

proc update_PARAM_VALUE.NUM_CORES { PARAM_VALUE.NUM_CORES } {
	# Procedure called to update NUM_CORES when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.NUM_CORES { PARAM_VALUE.NUM_CORES } {
	# Procedure called to validate NUM_CORES
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


proc update_MODELPARAM_VALUE.NUM_CORES { MODELPARAM_VALUE.NUM_CORES PARAM_VALUE.NUM_CORES } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.NUM_CORES}] ${MODELPARAM_VALUE.NUM_CORES}
}

proc update_MODELPARAM_VALUE.W { MODELPARAM_VALUE.W PARAM_VALUE.W } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.W}] ${MODELPARAM_VALUE.W}
}

proc update_MODELPARAM_VALUE.FRAC { MODELPARAM_VALUE.FRAC PARAM_VALUE.FRAC } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.FRAC}] ${MODELPARAM_VALUE.FRAC}
}

proc update_MODELPARAM_VALUE.SEQ_W { MODELPARAM_VALUE.SEQ_W PARAM_VALUE.SEQ_W } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.SEQ_W}] ${MODELPARAM_VALUE.SEQ_W}
}

proc update_MODELPARAM_VALUE.ITER_W { MODELPARAM_VALUE.ITER_W PARAM_VALUE.ITER_W } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.ITER_W}] ${MODELPARAM_VALUE.ITER_W}
}

proc update_MODELPARAM_VALUE.MODE_W { MODELPARAM_VALUE.MODE_W PARAM_VALUE.MODE_W } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.MODE_W}] ${MODELPARAM_VALUE.MODE_W}
}

proc update_MODELPARAM_VALUE.ESCAPE_THRESH_Q422 { MODELPARAM_VALUE.ESCAPE_THRESH_Q422 PARAM_VALUE.ESCAPE_THRESH_Q422 } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.ESCAPE_THRESH_Q422}] ${MODELPARAM_VALUE.ESCAPE_THRESH_Q422}
}

