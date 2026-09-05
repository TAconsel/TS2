library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- I2S master transmitter for the PCM5102(A) in slave mode.
--
-- The input clock is the audio master clock itself, 256 x Fs (12.288136 MHz
-- from audio_pll), so SCK is that clock and the rest are power-of-two taps off
-- one counter.  Nothing can drift out of phase with anything else:
--
--     clk    -> SCK  = 256 x Fs = 12.288136 MHz
--     div(1) -> BCK  = clk / 4  =  3.072034 MHz  = 64 x Fs
--     div(7) -> LRCK = clk / 256 = 48000.5297 Hz = Fs
--
-- 256 fS is one of the SCK ratios the PCM5102A accepts, and 64 BCK per frame
-- is the usual 32-bit-per-channel I2S frame.
--
-- Frame format is Philips I2S (PCM5102A with FMT tied low, the default on the
-- breakout modules): MSB first, LRCK low = left, and the MSB delayed by one
-- BCK period after the LRCK edge.  Of the 32 bit slots per channel, slot 0 is
-- that delay bit, slots 1..24 carry the sample and slots 25..31 are zero.
--
-- DIN is updated on the falling edge of BCK, giving the DAC half a bit period
-- (163 ns) of setup before it samples on the rising edge.

entity i2s_master is
    Port (
        clk       : in  STD_LOGIC;                -- 256 x Fs
        sample_l  : in  signed(23 downto 0);
        sample_r  : in  signed(23 downto 0);
        -- One clk-wide pulse at the start of each stereo frame, i.e. once per
        -- sample period.  The sample inputs are captured one clock earlier
        -- than this, so they must be steady between frames rather than
        -- changing in response to the pulse.
        frame_tick : out STD_LOGIC;
        i2s_sck   : out STD_LOGIC;
        i2s_bck   : out STD_LOGIC;
        i2s_lrck  : out STD_LOGIC;
        i2s_din   : out STD_LOGIC
    );
end i2s_master;

architecture Behavioral of i2s_master is

    signal div    : unsigned(7 downto 0) := (others => '0');
    signal shreg  : std_logic_vector(31 downto 0) := (others => '0');

    -- Both channels are transmitted from one snapshot taken just before the
    -- frame starts.  Without this the left half-frame (loaded at div = 255)
    -- and the right half-frame (loaded at div = 127) would come from
    -- different sample periods, putting a one-sample skew between channels.
    signal hold_l : std_logic_vector(23 downto 0) := (others => '0');
    signal hold_r : std_logic_vector(23 downto 0) := (others => '0');

begin

    process(clk)
    begin
        if rising_edge(clk) then

            div <= div + 1;

            -- One clock before the frame boundary, so the snapshot is already
            -- in place when the left half-frame loads below.
            if div = "11111110" then
                hold_l <= std_logic_vector(sample_l);
                hold_r <= std_logic_vector(sample_r);
            end if;

            -- div(1 downto 0) = "11" means BCK falls on this very edge, so
            -- registering the shift here lines the data change up with it.
            if div(1 downto 0) = "11" then

                if div(6 downto 0) = "1111111" then
                    -- LRCK also flips on this edge: load the half-frame that
                    -- is about to start.  div(7) is still the outgoing
                    -- channel, so the incoming one is its complement.
                    if div(7) = '1' then
                        shreg <= '0' & hold_l & "0000000";
                    else
                        shreg <= '0' & hold_r & "0000000";
                    end if;
                else
                    shreg <= shreg(30 downto 0) & '0';
                end if;

            end if;

        end if;
    end process;

    -- div = all ones is the load edge for the left channel, i.e. once per
    -- sample period.
    frame_tick <= '1' when div = "11111111" else '0';

    i2s_sck  <= clk;
    i2s_bck  <= div(1);
    i2s_lrck <= div(7);
    i2s_din  <= shreg(31);

end Behavioral;
