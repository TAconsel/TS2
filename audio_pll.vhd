library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- 50 MHz -> 49.147727 MHz, the audio clock for 384 kHz.
--
-- The I2S transmitter runs at twice the bit clock, and a frame of two 32-bit
-- slots needs BCK = 64 x Fs = 24.576 MHz, so the wanted clock is 49.152 MHz.
-- That is not reachable from a 50 MHz reference: the ratio is 3072/3125 and
-- 3125 = 5^5 shares no factor with 3072, so no legal M/N/C lands on it.  The
-- closest is
--
--     M = 173, N = 8, C = 22
--     fPFD = 50 / 8        =   6.250000 MHz   (spec 5 - 325)
--     fVCO = 50 * 173 / 8  = 1081.250000 MHz  (spec 600 - 1300)
--     fOUT = 1081.25 / 22  =   49.147727 MHz
--
-- Doubling this to 98.295455 MHz (C = 11) is what a 128 x Fs frame would need,
-- if a DAC ever wants full 32-bit Philips I2S; see i2s_master.vhd.
--
-- which puts Fs at 383966.6 Hz, 87 ppm below 384 kHz.  That does not matter
-- and is not a compromise: the device is an asynchronous USB audio sink and
-- reports the rate it actually runs at on its feedback endpoint, so the host
-- follows this clock rather than the other way round.  Pitch error of 87 ppm
-- is 0.15 cents.
--
-- Quartus derives M/N/C from the multiply/divide ratio below; 173/176 factors
-- as M = 173 over N*C = 8*22.  Check the PLL Summary in the fit report if the
-- reference clock ever changes.

entity audio_pll is
    Port (
        clk_in  : in  STD_LOGIC;   -- 50 MHz reference
        clk_out : out STD_LOGIC;   -- 49.147727 MHz, = 128 x Fs
        locked  : out STD_LOGIC
    );
end audio_pll;

architecture Behavioral of audio_pll is

begin

    -- apll.vhd is qmegawiz output.  ALTPLL will not solve its own M/N/C when
    -- hand-instantiated with only a multiply/divide ratio -- it emits
    -- m_initial = 0 and the fitter rejects it -- so the generated wrapper is
    -- used rather than an altpll instance written out here.
    pll : entity work.apll
        port map (
            areset => '0',
            inclk0 => clk_in,
            c0     => clk_out,
            locked => locked
        );

end Behavioral;
