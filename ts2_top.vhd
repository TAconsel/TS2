library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Top level: a USB audio device feeding a PCM5102(A) over I2S, falling back to
-- a 1 kHz sine test tone whenever nothing is playing, plus the original
-- blinking LED kept as an "FPGA is configured" indicator.
--
-- The audio path runs from audio_pll at 256 x Fs, putting Fs within 11 ppm of
-- 48 kHz.  The LED stays on the raw 50 MHz reference so it keeps indicating
-- life even if the PLL fails to lock.  The two domains never exchange data.
--
-- Board is the 10CL006YE144C8G core board (DEV190806037), 50 MHz TCXO on
-- FPGA_CLK / PIN_91.
--
--     PCM5102 module   FPGA pin
--     --------------   --------
--     LCK  (LRCK)      3
--     DIN              1
--     BCK              143
--     SCK  (MCLK)      141
--
-- A USB3300 ULPI PHY hangs off the other side, to turn the board into a USB
-- audio device.  Its CLK is an output: the PHY free-runs at 60 MHz from its
-- own crystal and everything on the ULPI bus is in that domain.
--
--     USB3300          FPGA pin
--     -------          --------
--     DATA0..7         31 32 33 34 38 39 42 43
--     STP              44
--     NXT              46
--     DIR              49
--     CLK              23   (a dedicated clock input)
--     RST              51
--
-- The CH340 on the core board carries the trace out at 1 Mbaud.
--
--     FPGA_TX          11

entity ts2_top is
    Generic (
        -- Adds the JTAG (In-System Sources and Probes) monitor.  Set false for
        -- a production build; it costs a JTAG hub and ~120 registers.
        DEBUG : boolean := true
    );
    Port (
        clk      : in  STD_LOGIC;   -- 50 MHz
        led      : out STD_LOGIC;
        -- SCK is bidirectional only so the debug monitor can stop driving it;
        -- with DEBUG = false the enable is constant and it becomes a plain
        -- output.
        i2s_sck  : inout STD_LOGIC;
        i2s_bck  : out   STD_LOGIC;
        i2s_lrck : out   STD_LOGIC;
        i2s_din  : out   STD_LOGIC;

        -- USB3300 ULPI PHY.
        ulpi_clk : in    STD_LOGIC;
        ulpi_d   : inout STD_LOGIC_VECTOR(7 downto 0);
        ulpi_dir : in    STD_LOGIC;
        ulpi_nxt : in    STD_LOGIC;
        ulpi_stp : out   STD_LOGIC;
        ulpi_rst : out   STD_LOGIC;

        -- Debug trace to the on-board CH340.
        uart_tx  : out   STD_LOGIC
    );
end ts2_top;

architecture Behavioral of ts2_top is

    signal tone_sample : signed(23 downto 0);
    signal usb_l, usb_r : signed(23 downto 0);
    signal usb_active   : STD_LOGIC;
    signal play_l, play_r : signed(23 downto 0);
    signal frame_tick   : STD_LOGIC;

    -- Internal copies of the bus, so the debug monitor can observe what the
    -- pins are driven with (an out port cannot be read in VHDL-93).
    signal sck_i, bck_i, lrck_i, din_i : STD_LOGIC;

    signal sck_off : STD_LOGIC := '0';

    signal aclk, pll_locked : STD_LOGIC;

begin

    audio_clk : entity work.audio_pll
        port map (
            clk_in  => clk,
            clk_out => aclk,
            locked  => pll_locked
        );

    -- Unchanged 0.5 s blink on the 50 MHz reference, so a dead board is easy
    -- to tell from a wiring problem on the DAC.
    blink : entity work.led_blink
        port map (
            clk => clk,
            led => led
        );

    tone : entity work.tone_gen
        port map (
            clk         => aclk,
            sample_tick => frame_tick,
            sample      => tone_sample
        );

    -- USB audio when the host is streaming, the test tone otherwise, so the
    -- board always says something and an unplugged cable is obvious.  The
    -- source only changes at a packet boundary, never mid-frame.
    play_l <= usb_l when usb_active = '1' else tone_sample;
    play_r <= usb_r when usb_active = '1' else tone_sample;

    i2s : entity work.i2s_master
        port map (
            clk        => aclk,
            sample_l   => play_l,
            sample_r   => play_r,
            frame_tick => frame_tick,
            i2s_sck    => sck_i,
            i2s_bck    => bck_i,
            i2s_lrck   => lrck_i,
            i2s_din    => din_i
        );

    -- Released SCK is what a module using its own internal PLL expects.
    i2s_sck  <= 'Z' when sck_off = '1' else sck_i;
    i2s_bck  <= bck_i;
    i2s_lrck <= lrck_i;
    -- Hold data at zero until the PLL is locked, so the DAC is not fed
    -- garbage clocked at an unsettled rate on power-up.
    i2s_din  <= din_i and pll_locked;

    usb : entity work.usb_top
        port map (
            clk_ref      => clk,
            ulpi_clk     => ulpi_clk,
            ulpi_d       => ulpi_d,
            ulpi_dir     => ulpi_dir,
            ulpi_nxt     => ulpi_nxt,
            ulpi_stp     => ulpi_stp,
            ulpi_rst     => ulpi_rst,
            uart_tx      => uart_tx,
            aclk         => aclk,
            frame_tick   => frame_tick,
            sample_l     => usb_l,
            sample_r     => usb_r,
            audio_active => usb_active
        );

    -- Reads back a decoded frame and the measured sample rate over JTAG.
    dbg_gen : if DEBUG generate
        monitor : entity work.i2s_monitor
            port map (
                clk        => aclk,
                i2s_bck    => bck_i,
                i2s_lrck   => lrck_i,
                i2s_din    => din_i,
                sample_ref => play_l,
                pll_locked => pll_locked,
                sck_off    => sck_off
            );
    end generate;

end Behavioral;
