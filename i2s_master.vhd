library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- I2S master transmitter for a DAC in slave mode.
--
-- The word length and the frame size are generics, because they are the two
-- things a change of DAC is most likely to move:
--
--   SLOT_BITS  bit clocks per channel, so the frame is twice this
--   DATA_BITS  bits of the sample actually sent, most significant first
--
-- Philips I2S spends the first bit time of each slot on the format's one-clock
-- delay, so DATA_BITS can be at most SLOT_BITS - 1.  That is why a 32-bit word
-- does not fit a 32-bit slot: 64 x Fs carries 24-bit audio comfortably and
-- 32-bit audio not at all, and 128 x Fs is what full 32-bit costs.
--
--   SLOT_BITS = 64, DATA_BITS = 32   full 32-bit, BCK = 128 x Fs   (default)
--   SLOT_BITS = 32, DATA_BITS = 24   24-bit,      BCK =  64 x Fs
--
-- The input clock is twice the bit clock, and everything else is a
-- power-of-two tap off one counter, so nothing can drift out of phase with
-- anything else.  With the default generics at 384 kHz:
--
--     clk    -> 256 x Fs = 98.295455 MHz
--     div(0) -> BCK  = clk / 2   = 49.147727 MHz = 128 x Fs
--     div(7) -> LRCK = clk / 256 = 383966.6 Hz   = Fs
--
-- SCK (the DAC's master clock) is not driven.  The PCM5102A wants it at
-- 256 x Fs, which at 384 kHz would be another 98.3 MHz pin, and grounding it
-- instead puts the part in BCK-only mode where its own PLL derives the system
-- clock from BCK.  That is what these breakout modules are built for.
--
-- Frame format is Philips I2S (PCM5102A with FMT tied low, the default on the
-- breakout modules): MSB first, LRCK low = left, and the MSB delayed by one
-- BCK period after the LRCK edge.  DIN is updated on the falling edge of BCK,
-- giving the DAC half a bit period of setup before it samples on the rising
-- edge.

entity i2s_master is
    Generic (
        SLOT_BITS : natural := 64;
        DATA_BITS : natural := 32
    );
    Port (
        clk       : in  STD_LOGIC;                -- 4 x SLOT_BITS x Fs
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

    function log2ceil(n : natural) return natural is
        variable r : natural := 0;
        variable v : natural := n - 1;
    begin
        while v > 0 loop
            r := r + 1;
            v := v / 2;
        end loop;
        return r;
    end function;

    -- One frame is two slots of SLOT_BITS bit clocks, and the counter runs at
    -- twice the bit clock.
    constant DIV_BITS : natural := log2ceil(4 * SLOT_BITS);

    signal div   : unsigned(DIV_BITS-1 downto 0) := (others => '0');
    signal shreg : std_logic_vector(SLOT_BITS-1 downto 0) := (others => '0');

    -- Both channels are transmitted from one snapshot taken just before the
    -- frame starts.  Without this the left half-frame and the right half-frame
    -- would come from different sample periods, putting a one-sample skew
    -- between channels.
    signal hold_l : std_logic_vector(31 downto 0) := (others => '0');
    signal hold_r : std_logic_vector(31 downto 0) := (others => '0');

    constant ALL_ONES : unsigned(DIV_BITS-1 downto 0) := (others => '1');
    -- The slot holds the delay bit, then the data, then zeros.  A null range
    -- here is legal and is what DATA_BITS = SLOT_BITS - 1 gives.
    constant PAD      : std_logic_vector(SLOT_BITS-2-DATA_BITS downto 0)
                        := (others => '0');

begin

    process(clk)
    begin
        if rising_edge(clk) then

            div <= div + 1;

            -- One clock before the frame boundary, so the snapshot is already
            -- in place when the left half-frame loads below.
            if div = ALL_ONES - 1 then
                hold_l <= std_logic_vector(sample_l);
                hold_r <= std_logic_vector(sample_r);
            end if;

            -- div(0) = '1' means BCK falls on this very edge, so registering
            -- the shift here lines the data change up with it.
            if div(0) = '1' then

                if div(DIV_BITS-2 downto 0) = ALL_ONES(DIV_BITS-2 downto 0) then
                    -- LRCK also flips on this edge: load the half-frame that
                    -- is about to start.  The top div bit is still the
                    -- outgoing channel, so the incoming one is its complement.
                    if div(DIV_BITS-1) = '1' then
                        shreg <= '0' & hold_l(31 downto 32-DATA_BITS) & PAD;
                    else
                        shreg <= '0' & hold_r(31 downto 32-DATA_BITS) & PAD;
                    end if;
                else
                    shreg <= shreg(SLOT_BITS-2 downto 0) & '0';
                end if;

            end if;

        end if;
    end process;

    -- div all ones is the load edge for the left channel, i.e. once per
    -- sample period.
    frame_tick <= '1' when div = ALL_ONES else '0';

    i2s_bck  <= div(0);
    i2s_lrck <= div(DIV_BITS-1);
    i2s_din  <= shreg(SLOT_BITS-1);

end Behavioral;
