# FractalScope Master Build Script


set project_name "fractalscope"
set project_dir "./vivado_project"
set part "xc7z020clg400-1" ;

puts "Creating Project: $project_name"
create_project $project_name $project_dir -part $part -force

# 1. Point Vivado to your custom IP folder
puts "Loading Custom IPs..."
set_property ip_repo_paths {./ip_repo ./ext/vivado-library  } [current_project]
update_ip_catalog

# 2. Add your constraints (HDMI pins, etc.)
add_files -fileset constrs_1 -norecurse ./constrs/pins.xdc

# 3. Draw the Block Design
puts "Building Block Design..."
source ./build_bd.tcl

# 4. Create the HDL Wrapper for the Block Design
puts "Generating HDL Wrapper..."
set bd_name "main_v1"
make_wrapper -files [get_files ${bd_name}.bd] -top
add_files -norecurse ${project_dir}/${project_name}.gen/sources_1/bd/${bd_name}/hdl/${bd_name}_wrapper.v

# 5. Set the Wrapper as the Top module
set_property top ${bd_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1

puts "SUCCESS: Project generation complete!"
