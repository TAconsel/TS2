library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library altera_mf;
use altera_mf.altera_mf_components.all;

-- JTAG debug monitor, read at runtime with In-System Sources and Probes
-- (quartus_stp_tcl -> read_probe_data / write_source_data).
--
-- It re-decodes the I2S bus the way the PCM5102 does -- sampling DIN on the
-- rising edge of BCK -- rather than looking at the transmitter's internals, so
-- a frame read back over JTAG is evidence about the bus itself and not just a
-- copy of the shift register.
--
-- Probe layout, MSB first as read_probe_data returns it.  Its width follows
-- SLOT_BITS: 1 + 2*SLOT_BITS + 32 + 19 + 11, which is 191 bits by default.
--     top      : PLL locked
--     then     : one complete stereo frame, 2*SLOT_BITS bits, left slot first
--     then     : the 32-bit sample the source presented at the capture
--                instant.  This leads the frame by one sample period, because
--                i2s_master transmits from a snapshot taken just before the
--                frame starts.
--      29..11  : LRCK edges over one second of audio clock = Fs in Hz (383967)
--      10.. 0  : negative-to-positive crossings of the transmitted left sample
--                over the same gate = tone frequency in Hz (1000)
--
-- Source bits:
--     0 : freeze the reported values so repeated reads are coherent
--
-- Note: there is deliberately no pad-level readback here.  Reading an inout
-- port back in VHDL returns this entity's own driver rather than the pad, so
-- such a "measurement" only ever echoes what we drive.  Checking whether a
-- module grounds SCK is a multimeter job, not an FPGA one.

entity i2s_monitor is
    Generic (
        -- Framing, matching i2s_master.  The captured frame is twice
        -- SLOT_BITS, and the probe grows with it.
        SLOT_BITS      : natural := 32;
        LEFT_JUSTIFIED : boolean := false
    );
    Port (
        clk        : in STD_LOGIC;
        i2s_bck    : in STD_LOGIC;
        i2s_lrck   : in STD_LOGIC;
        i2s_din    : in STD_LOGIC;
        sample_ref : in signed(31 downto 0);
        pll_locked : in STD_LOGIC
    );
end i2s_monitor;

architecture Behavioral of i2s_monitor is

    -- One second of the 49.147727 MHz audio clock.  The clock is not an
    -- integer number of Hz, so the gate is a few ppb long -- far below the
    -- +-1 count quantisation of the results it gates.
    constant ONE_SECOND : natural := 49147727;

    signal bck_d, lrck_d : STD_LOGIC := '0';
    signal bck_rise, lrck_rise, frame_end : STD_LOGIC;

    constant FRAME_BITS : natural := 2 * SLOT_BITS;

    signal bit_sr   : std_logic_vector(FRAME_BITS-1 downto 0) := (others => '0');
    signal snapshot : std_logic_vector(FRAME_BITS-1 downto 0) := (others => '0');
    signal snap_ref : std_logic_vector(31 downto 0) := (others => '0');

    signal sec_count   : unsigned(26 downto 0) := (others => '0');
    signal gate_end    : STD_LOGIC;

    -- 19 bits: 384 kHz needs more room than 48 kHz did, and a counter that
    -- silently wraps reports a plausible-looking wrong answer.
    signal lrck_count, fs_result : unsigned(18 downto 0) := (others => '0');

    -- Sign of the left sample in the frame that just finished, used to count
    -- one crossing per period of the tone.
    signal prev_sign   : STD_LOGIC := '0';
    signal cross       : STD_LOGIC;
    signal sign_bit    : STD_LOGIC;
    signal tone_count, tone_result : unsigned(10 downto 0) := (others => '0');

    -- PLL locked, the frame, the reference sample, Fs and the tone count.
    constant PROBE_BITS : natural := 1 + FRAME_BITS + 32 + 19 + 11;
    signal probe  : std_logic_vector(PROBE_BITS-1 downto 0);
    signal source : std_logic_vector(1 downto 0);
    signal freeze : STD_LOGIC;

begin

    freeze  <= source(0);

    -- BCK/LRCK are registered outputs of this same clock, so edge detection
    -- here is ordinary synchronous logic with no crossing involved.
    bck_rise  <= '1' when bck_d  = '0' and i2s_bck  = '1' else '0';
    lrck_rise <= '1' when lrck_d = '0' and i2s_lrck = '1' else '0';

    -- LRCK falling edge: a stereo frame just completed, so bit_sr holds it
    -- whole -- the left slot then the right one.
    frame_end <= '1' when lrck_d = '1' and i2s_lrck = '0' else '0';

    gate_end <= '1' when sec_count = to_unsigned(ONE_SECOND - 1,
                                                 sec_count'length) else '0';

    -- The sample's sign bit: the top of the left slot, or one below it when
    -- the format spends that bit on its delay.
    sign_bit <= bit_sr(FRAME_BITS-1) when LEFT_JUSTIFIED
                else bit_sr(FRAME_BITS-2);

    cross <= '1' when frame_end = '1' and prev_sign = '1' and sign_bit = '0'
             else '0';

    process(clk)
    begin
        if rising_edge(clk) then

            bck_d  <= i2s_bck;
            lrck_d <= i2s_lrck;

            -- Sample DIN exactly where the DAC latches it.
            if bck_rise = '1' then
                bit_sr <= bit_sr(FRAME_BITS-2 downto 0) & i2s_din;
            end if;

            if frame_end = '1' then
                prev_sign <= sign_bit;
                if freeze = '0' then
                    snapshot <= bit_sr;
                    snap_ref <= std_logic_vector(sample_ref);
                end if;
            end if;

            -- One-second gate.  An event landing on the gate boundary is
            -- counted into the result rather than lost to the reset.
            if gate_end = '1' then
                sec_count  <= (others => '0');
                lrck_count <= (others => '0');
                tone_count <= (others => '0');
                if freeze = '0' then
                    fs_result   <= lrck_count + ("" & lrck_rise);
                    tone_result <= tone_count + ("" & cross);
                end if;
            else
                sec_count  <= sec_count + 1;
                lrck_count <= lrck_count + ("" & lrck_rise);
                tone_count <= tone_count + ("" & cross);
            end if;

        end if;
    end process;

    probe <= pll_locked & snapshot & snap_ref & std_logic_vector(fs_result)
             & std_logic_vector(tone_result);

    issp : altsource_probe
        generic map (
            instance_id            => "I2SM",
            probe_width            => PROBE_BITS,
            source_width           => 2,
            source_initial_value   => "0",
            enable_metastability   => "YES"
        )
        port map (
            probe      => probe,
            source     => source,
            source_clk => clk,
            source_ena => '1'
        );

end Behavioral;
