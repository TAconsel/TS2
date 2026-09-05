library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

library altera_mf;
use altera_mf.altera_mf_components.all;

-- 50 MHz -> 12.288136 MHz audio master clock.
--
-- 12.288 MHz exactly (256 x 48 kHz) is NOT reachable from a 50 MHz reference
-- on this PLL.  The required ratio is 3072/3125, and 3125 = 5^5 shares no
-- factor with 3072, so realising it needs M > 512 for any VCO frequency in
-- the legal 600-1300 MHz window.  The closest legal setting is
--
--     M = 29, N = 2, C = 59
--     fPFD = 50 / 2      =  25.000000 MHz   (spec 5 - 325)
--     fVCO = 50 * 29 / 2 = 725.000000 MHz   (spec 600 - 1300)
--     fOUT = 725 / 59    =  12.288136 MHz
--
-- which puts Fs at 48000.5297 Hz, i.e. +11 ppm -- tighter than a typical
-- crystal, against +17253 ppm for the PLL-less 50/1024 divide.
--
-- Quartus derives M/N/C from the multiply/divide ratio below; 29/118 factors
-- as M = 29 over N*C = 2*59.  Check the PLL Summary in the fit report if the
-- reference clock ever changes.

entity audio_pll is
    Port (
        clk_in  : in  STD_LOGIC;   -- 50 MHz reference
        clk_out : out STD_LOGIC;   -- 12.288136 MHz, = 256 x Fs
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
