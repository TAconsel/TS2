library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Sine test tone generator.
--
-- A phase accumulator is advanced once per sample tick; its top 8 bits index
-- the sine ROM.  Output tone frequency is
--
--     f_tone = PHASE_INC * Fs / 2**PHASE_BITS
--
-- so for a wanted frequency the increment is
--
--     PHASE_INC = round(f_tone * 2**PHASE_BITS / Fs)
--
-- With Fs = 383966.6193 Hz and PHASE_BITS = 24 that is 43.69445 per Hz,
-- giving a tuning resolution of 22.9 mHz.

entity tone_gen is
    Generic (
        -- 1 kHz: round(1000 * 2**24 / 383966.6193) = 43694  ->  999.9894 Hz
        PHASE_INC    : natural := 43694;
        -- Output attenuation in 6 dB steps.  1 => -6 dBFS, a conventional
        -- test tone level that leaves headroom in the DAC's reconstruction
        -- filter.  0 would be full scale.
        ATTEN_SHIFT  : natural := 1
    );
    Port (
        clk        : in  STD_LOGIC;
        -- One clk-wide pulse, once per sample period.
        sample_tick : in  STD_LOGIC;
        -- 32-bit signed sample, MSB aligned for the I2S transmitter.
        sample     : out signed(31 downto 0)
    );
end tone_gen;

architecture Behavioral of tone_gen is

    constant PHASE_BITS : natural := 24;

    signal phase      : unsigned(PHASE_BITS-1 downto 0) := (others => '0');
    signal rom_data   : signed(15 downto 0);
    signal attenuated : signed(15 downto 0);

begin

    process(clk)
    begin
        if rising_edge(clk) then
            if sample_tick = '1' then
                phase <= phase + to_unsigned(PHASE_INC, PHASE_BITS);
            end if;
        end if;
    end process;

    -- The ROM is read continuously; the address only changes once per sample
    -- period, so its output is settled long before the next tick.
    rom : entity work.sine_rom
        port map (
            clk  => clk,
            addr => phase(PHASE_BITS-1 downto PHASE_BITS-8),
            data => rom_data
        );

    -- Attenuate (arithmetic shift, so the sign is preserved), then place the
    -- 16-bit table value in the top of the 32-bit word with the low 16 bits
    -- left at zero.  A shift by 0 is legal, so ATTEN_SHIFT = 0 needs no
    -- special case.
    attenuated <= shift_right(rom_data, ATTEN_SHIFT);
    sample     <= shift_left(resize(attenuated, 32), 16);

end Behavioral;
