# Reads the i2s_monitor probe over JTAG via In-System Sources and Probes.
#   quartus_stp_tcl -t debug/read_i2s.tcl [num_reads]
# Emits "PROBE <n>: <bits>" lines for debug/decode_i2s.py to decode.
#
# Requires a bitstream built with ts2_top's DEBUG generic true.

package require ::quartus::insystem_source_probe
package require ::quartus::jtag

set reads 8
if {$argc >= 1} { set reads [lindex $argv 0] }

set hw [lindex [get_hardware_names] 0]
if {$hw eq ""} { puts "ERROR: no programming cable found"; exit 1 }
set dev [lindex [get_device_names -hardware_name $hw] 0]

puts "HW: $hw"
puts "DEV: $dev"

# Must be queried before a session is started, or it reports a session clash.
set info [get_insystem_source_probe_instance_info \
              -device_name $dev -hardware_name $hw]
puts "INFO: $info"
if {$info eq ""} { puts "ERROR: no Source/Probe instance -- DEBUG build?"; exit 1 }

start_insystem_source_probe -device_name $dev -hardware_name $hw
for {set i 0} {$i < $reads} {incr i} {
    # Release the freeze so a fresh frame is captured, then hold it so the
    # 116-bit read is coherent.
    write_source_data -instance_index 0 -value 0
    after 60
    write_source_data -instance_index 0 -value 1
    puts "PROBE $i: [read_probe_data -instance_index 0]"
}
write_source_data -instance_index 0 -value 0
end_insystem_source_probe
