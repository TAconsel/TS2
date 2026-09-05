# Start/stop driving SCK at runtime, no rebuild.
#   quartus_stp_tcl -t debug/sck_toggle.tcl on    -> FPGA drives SCK (256 x Fs)
#   quartus_stp_tcl -t debug/sck_toggle.tcl off   -> SCK released (module's
#                                                    internal PLL, SCK=GND)
# Source bit 0 is freeze, bit 1 is sck_off.

package require ::quartus::insystem_source_probe
package require ::quartus::jtag

set mode "off"
if {$argc >= 1} { set mode [lindex $argv 0] }

set hw [lindex [get_hardware_names] 0]
set dev [lindex [get_device_names -hardware_name $hw] 0]
start_insystem_source_probe -device_name $dev -hardware_name $hw
if {$mode eq "off"} {
    write_source_data -instance_index 0 -value 2
    puts "SCK: released (not driven) -- module must supply its own via BCK PLL"
} else {
    write_source_data -instance_index 0 -value 0
    puts "SCK: driven at 12.5 MHz (256 x Fs)"
}
end_insystem_source_probe
