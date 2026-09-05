library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- I2S master transmitter for the PCM5102(A) in slave mode.
--
-- The input clock is twice the bit clock, and everything else is a
-- power-of-two tap off one counter, so nothing can drift out of phase with
-- anything else:
--
--     clk    -> 128 x Fs = 49.147727 MHz
--     div(0) -> BCK  = clk / 2   = 24.573864 MHz = 64 x Fs
--     div(6) -> LRCK = clk / 128 = 383966.6 Hz   = Fs
--
-- 64 BCK per frame is the usual two-32-bit-slot I2S frame.
--
-- SCK (the DAC's master clock) is not driven at this rate.  The PCM5102A
-- wants it at 256 x Fs, which would be 98.3 MHz -- beyond what this part will
-- generate cleanly and well beyond what a jumper wire will carry.  Grounding
-- SCK instead puts the DAC in BCK-only mode, where its own PLL derives the
-- system clock from BCK, which is what these breakout modules are built for.
--
-- Frame format is Philips I2S (PCM5102A with FMT tied low, the default on the
-- breakout modules): MSB first, LRCK low = left, and the MSB delayed by one
-- BCK period after the LRCK edge.  Of the 32 bit slots per channel, slot 0 is
-- that delay bit, slots 1..24 carry the sample and slots 25..31 are zero.
--
-- The samples arriving from USB are 32-bit and the top 24 go to the DAC.  A
-- 32-bit word does not fit an I2S slot at 64 x Fs: one bit of the 32 is spent
-- on the format's delay, so 31 would be the most, and the DAC expects a whole
-- number of bytes.  Nothing is lost that the part could reproduce -- the
-- PCM5102A's dynamic range is 112 dB, about 19 bits, so bits below the 24th
-- are some 30 dB under its own noise floor.
--
-- DIN is updated on the falling edge of BCK, giving the DAC half a bit period
-- (20 ns) of setup before it samples on the rising edge.

entity i2s_master is
    Port (
        clk       : in  STD_LOGIC;                -- 128 x Fs
        sample_l  : in  signed(31 downto 0);
        sample_r  : in  signed(31 downto 0);
        -- One clk-wide pulse at the start of each stereo frame, i.e. once per
        -- sample period.  The sample inputs are captured one clock earlier
        -- than this, so they must be steady between frames rather than
        -- changing in response to the pulse.
        frame_tick : out STD_LOGIC;
        i2s_bck   : out STD_LOGIC;
        i2s_lrck  : out STD_LOGIC;
        i2s_din   : out STD_LOGIC
    );
end i2s_master;

architecture Behavioral of i2s_master is

    signal div    : unsigned(6 downto 0) := (others => '0');
    signal shreg  : std_logic_vector(31 downto 0) := (others => '0');

    -- Both channels are transmitted from one snapshot taken just before the
    -- frame starts.  Without this the left half-frame (loaded at div = 127)
    -- and the right half-frame (loaded at div = 63) would come from different
    -- sample periods, putting a one-sample skew between channels.
    signal hold_l : std_logic_vector(31 downto 0) := (others => '0');
    signal hold_r : std_logic_vector(31 downto 0) := (others => '0');

begin

    process(clk)
    begin
        if rising_edge(clk) then

            div <= div + 1;

            -- One clock before the frame boundary, so the snapshot is already
            -- in place when the left half-frame loads below.
            if div = "1111110" then
                hold_l <= std_logic_vector(sample_l);
                hold_r <= std_logic_vector(sample_r);
            end if;

            -- div(0) = '1' means BCK falls on this very edge, so registering
            -- the shift here lines the data change up with it.
            if div(0) = '1' then

                if div(5 downto 0) = "111111" then
                    -- LRCK also flips on this edge: load the half-frame that
                    -- is about to start.  div(6) is still the outgoing
                    -- channel, so the incoming one is its complement.
                    if div(6) = '1' then
                        shreg <= '0' & hold_l(31 downto 8) & "0000000";
                    else
                        shreg <= '0' & hold_r(31 downto 8) & "0000000";
                    end if;
                else
                    shreg <= shreg(30 downto 0) & '0';
                end if;

            end if;

        end if;
    end process;

    -- div = all ones is the load edge for the left channel, i.e. once per
    -- sample period.
    frame_tick <= '1' when div = "1111111" else '0';

    i2s_bck  <= div(0);
    i2s_lrck <= div(6);
    i2s_din  <= shreg(31);

end Behavioral;
