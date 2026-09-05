# 50 MHz TCXO (EC3233/50M) on FPGA_CLK / PIN_91.
create_clock -name clk -period 20.000 [get_ports clk]

# Picks up the audio_pll output automatically.
derive_pll_clocks

derive_clock_uncertainty

# SCK/BCK/LRCK are counter bits, not clocks feeding logic inside the FPGA, and
# the PCM5102 is fed asynchronously to any internal path, so the I2S outputs
# are not timed against the source clock.
set_false_path -to [get_ports {i2s_sck i2s_bck i2s_lrck i2s_din}]
set_false_path -to [get_ports {led}]

# The USB3300 generates its own 60 MHz and clocks the ULPI bus with it, so it
# is a source-synchronous input clock, not something derived from the TCXO.
create_clock -name ulpi_clk -period 16.667 [get_ports ulpi_clk]

# ULPI 1.1 bus timing at the connector.  The PHY presents DIR/NXT/DATA at most
# 9 ns after its own clock edge, and needs the link's DATA/STP set up 6 ns
# before that edge with no hold requirement.  Both halves are budgeted against
# the same clock because the PHY sources it.
set_input_delay  -clock ulpi_clk -max 9.0 [get_ports {ulpi_d[*] ulpi_dir ulpi_nxt}]
set_input_delay  -clock ulpi_clk -min 0.0 [get_ports {ulpi_d[*] ulpi_dir ulpi_nxt}]
set_output_delay -clock ulpi_clk -max 6.0 [get_ports {ulpi_d[*] ulpi_stp}]
set_output_delay -clock ulpi_clk -min 0.0 [get_ports {ulpi_d[*] ulpi_stp}]

# The data bus output enable is combinational on the DIR pin by design: the
# link has to be off the bus inside the single turnaround cycle, and a
# registered enable would release a cycle too late.  ULPI defines that cycle
# as invalid with both ends briefly driving, so this pin-to-pin path has no
# launch-to-latch relationship to meet -- it just has to be short, which it is
# (~8.7 ns worst case, against the 16.7 ns cycle).
set_false_path -from [get_ports ulpi_dir] -to [get_ports {ulpi_d[*]}]

# The registered half of the same output enable, which holds the link off the
# bus for one cycle after DIR falls.  It is not a data path either: the link's
# state machine will not issue a command until the cycle after that, and until
# it does the bus reads as the idle byte whether the link is driving zero or
# has not taken over yet.  So the enable only has to arrive within a cycle,
# not meet the 6 ns data setup the constraint above would impose on it.
set_false_path -from [get_registers {*|ulpi:bus_master|dir_q}] \
    -to [get_ports {ulpi_d[*]}]

# The PHY reset and the debug UART are asynchronous to everything.
set_false_path -to [get_ports {ulpi_rst uart_tx}]

# The TCXO, the PHY clock and the audio PLL are three unrelated sources; every
# path between them is through a resynchroniser or a dual-clock FIFO.
set_clock_groups -asynchronous \
    -group {clk audio_clk|pll|altpll_component|auto_generated|pll1|clk[0]} \
    -group {ulpi_clk}

# JTAG clock, present only when the debug monitor (SLD hub) is compiled in.
# Guarded so the constraint is harmless in a DEBUG = false build.
if {[llength [get_ports -nowarn altera_reserved_tck]]} {
    create_clock -name altera_reserved_tck -period 100.000 \
        [get_ports altera_reserved_tck]
    set_clock_groups -asynchronous \
        -group {altera_reserved_tck} \
        -group {clk} \
        -group {ulpi_clk}
}
