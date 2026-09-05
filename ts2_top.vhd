library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Top level: a USB audio device feeding a PCM5102(A) over I2S, plus the
-- original blinking LED kept as an "FPGA is configured" indicator.
--
-- With nothing streaming the DAC is fed silence.  The bit clock and word clock
-- keep running, so the converter stays locked and there is no thump when audio
-- resumes -- only the data goes to zero.  A 1 kHz test tone can be put there
-- instead by setting IDLE_TONE, which is how the audio path was brought up
-- before there was any USB to play through it.
--
-- The stream is 384 kHz, 32-bit, stereo, which needs USB high speed: at
-- 3.07 MB/s it does not fit a full-speed frame.  The device attaches at full
-- speed and negotiates up when the host resets the bus.
--
-- The audio path runs from audio_pll at 128 x Fs, putting Fs within 87 ppm of
-- 384 kHz -- which does not matter, because the device reports the rate it
-- actually runs at on its feedback endpoint and the host follows it.  The LED
-- stays on the raw 50 MHz reference so it keeps indicating life even if the
-- PLL fails to lock.
--
-- Board is the 10CL006YE144C8G core board (DEV190806037), 50 MHz TCXO on
-- FPGA_CLK / PIN_91.
--
--     PCM5102 module   FPGA pin
--     --------------   --------
--     LCK  (LRCK)      3
--     DIN              1
--     BCK              143
--     SCK  (MCLK)      141   held low: the DAC uses its own PLL
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
        DEBUG : boolean := true;
        -- I2S framing, passed to the transmitter and the monitor together.
        -- The default is the 64-bit-clock frame a PCM5102A works out for
        -- itself; 32/32/true sends a full 32-bit word at the same bit clock
        -- but needs the DAC's FMT pin high, and 64/32/false sends one in
        -- Philips I2S at twice the bit clock.  See i2s_master.vhd.
        SLOT_BITS      : natural := 32;
        DATA_BITS      : natural := 24;
        LEFT_JUSTIFIED : boolean := false;
        -- Play a 1 kHz sine when nothing is streaming, rather than silence.
        -- Useful for bringing the audio path up on its own; a nuisance
        -- otherwise, since it is the DAC's output that has to sit and hum.
        IDLE_TONE      : boolean := false
    );
    Port (
        clk      : in  STD_LOGIC;   -- 50 MHz
        led      : out STD_LOGIC;
        -- SCK is held low: see the note by the assignment below.
        i2s_sck  : out   STD_LOGIC;
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

    -- What the DAC is fed when the host is not streaming.
    signal idle_sample : signed(31 downto 0);
    signal usb_l, usb_r : signed(31 downto 0);
    signal usb_active   : STD_LOGIC;
    signal play_l, play_r : signed(31 downto 0);
    signal frame_tick   : STD_LOGIC;

    -- Internal copies of the bus, so the debug monitor can observe what the
    -- pins are driven with (an out port cannot be read in VHDL-93).
    signal bck_i, lrck_i, din_i : STD_LOGIC;

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

    tone_on : if IDLE_TONE generate
        tone : entity work.tone_gen
            port map (
                clk         => aclk,
                sample_tick => frame_tick,
                sample      => idle_sample
            );
    end generate;

    tone_off : if not IDLE_TONE generate
        idle_sample <= (others => '0');
    end generate;

    -- USB audio while the host is streaming, and whatever idle is otherwise.
    -- The source only changes at a packet boundary, never mid-frame.
    play_l <= usb_l when usb_active = '1' else idle_sample;
    play_r <= usb_r when usb_active = '1' else idle_sample;

    i2s : entity work.i2s_master
        generic map (SLOT_BITS      => SLOT_BITS,
                     DATA_BITS      => DATA_BITS,
                     LEFT_JUSTIFIED => LEFT_JUSTIFIED)
        port map (
            clk        => aclk,
            sample_l   => play_l,
            sample_r   => play_r,
            frame_tick => frame_tick,
            i2s_bck    => bck_i,
            i2s_lrck   => lrck_i,
            i2s_din    => din_i
        );

    -- SCK is held low, which puts the DAC in BCK-only mode and lets its own
    -- PLL derive the system clock.  At 384 kHz the alternative, 256 x Fs, is
    -- 98.3 MHz: past what this part will generate cleanly and well past what
    -- a jumper wire will carry.
    i2s_sck  <= '0';
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
            generic map (SLOT_BITS      => SLOT_BITS,
                         LEFT_JUSTIFIED => LEFT_JUSTIFIED)
            port map (
                clk        => aclk,
                i2s_bck    => bck_i,
                i2s_lrck   => lrck_i,
                i2s_din    => din_i,
                sample_ref => play_l,
                pll_locked => pll_locked
            );
    end generate;

end Behavioral;
