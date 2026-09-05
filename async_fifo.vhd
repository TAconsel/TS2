library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Dual-clock FIFO, gray-coded pointers, M9K-inferring.
--
-- Used twice: to carry trace bytes from the ULPI clock domain out to the UART
-- on the 50 MHz reference, and to carry audio samples from the ULPI domain to
-- the audio clock domain.  The two sides of this design never share a clock --
-- the PHY's 60 MHz, the board's 50 MHz and the PLL's 12.288 MHz are all
-- independent -- so every crossing goes through one of these.
--
-- rd_data is registered: it is valid the cycle AFTER rd_en is asserted, not on
-- the same cycle.  Reads must only be issued while empty is low.

entity async_fifo is
    Generic (
        WIDTH     : natural := 8;
        -- FIFO holds 2**ADDR_BITS entries.
        ADDR_BITS : natural := 10
    );
    Port (
        wr_clk  : in  STD_LOGIC;
        wr_en   : in  STD_LOGIC;
        wr_data : in  STD_LOGIC_VECTOR(WIDTH-1 downto 0);
        full    : out STD_LOGIC;

        rd_clk  : in  STD_LOGIC;
        rd_en   : in  STD_LOGIC;
        rd_data : out STD_LOGIC_VECTOR(WIDTH-1 downto 0);
        empty   : out STD_LOGIC;
        -- Occupancy, one copy in each domain.  Each lags the far side by its
        -- pointer synchroniser, so rd_level never over-reports what can be
        -- read and wr_level never under-reports what has been written.
        rd_level : out unsigned(ADDR_BITS downto 0);
        wr_level : out unsigned(ADDR_BITS downto 0)
    );
end async_fifo;

architecture Behavioral of async_fifo is

    -- Named rather than written inline: an anonymous 2**ADDR_BITS bound is a
    -- universal integer, which VHDL-93 will not accept as a range.
    constant DEPTH : integer := 2**ADDR_BITS;

    type ram_t is array (0 to DEPTH - 1)
        of STD_LOGIC_VECTOR(WIDTH-1 downto 0);
    signal ram : ram_t;

    -- One bit wider than the address so that a full FIFO is distinguishable
    -- from an empty one by the extra wrap bit.
    signal wr_bin,  wr_gray  : unsigned(ADDR_BITS downto 0) := (others => '0');
    signal rd_bin,  rd_gray  : unsigned(ADDR_BITS downto 0) := (others => '0');

    signal wr_gray_s1, wr_gray_s2 : unsigned(ADDR_BITS downto 0) := (others => '0');
    signal rd_gray_s1, rd_gray_s2 : unsigned(ADDR_BITS downto 0) := (others => '0');

    signal full_i, empty_i : STD_LOGIC;

    function to_gray(b : unsigned) return unsigned is
    begin
        return b xor ('0' & b(b'high downto 1));
    end function;

    function from_gray(g : unsigned) return unsigned is
        variable b : unsigned(g'range);
    begin
        b(g'high) := g(g'high);
        for i in g'high - 1 downto 0 loop
            b(i) := b(i+1) xor g(i);
        end loop;
        return b;
    end function;

begin

    ----------------------------------------------------------------------
    -- Write side
    ----------------------------------------------------------------------
    process(wr_clk)
    begin
        if rising_edge(wr_clk) then
            if wr_en = '1' and full_i = '0' then
                ram(to_integer(wr_bin(ADDR_BITS-1 downto 0))) <= wr_data;
                wr_bin  <= wr_bin + 1;
                wr_gray <= to_gray(wr_bin + 1);
            end if;
            rd_gray_s1 <= rd_gray;
            rd_gray_s2 <= rd_gray_s1;
        end if;
    end process;

    -- Full when the pointers are a whole lap apart, which in gray code is the
    -- top two bits differing and the rest equal.
    full_i <= '1' when wr_gray(ADDR_BITS)     /= rd_gray_s2(ADDR_BITS)
                   and wr_gray(ADDR_BITS-1)   /= rd_gray_s2(ADDR_BITS-1)
                   and wr_gray(ADDR_BITS-2 downto 0) = rd_gray_s2(ADDR_BITS-2 downto 0)
              else '0';
    full <= full_i;

    ----------------------------------------------------------------------
    -- Read side
    ----------------------------------------------------------------------
    process(rd_clk)
    begin
        if rising_edge(rd_clk) then
            if rd_en = '1' and empty_i = '0' then
                rd_data <= ram(to_integer(rd_bin(ADDR_BITS-1 downto 0)));
                rd_bin  <= rd_bin + 1;
                rd_gray <= to_gray(rd_bin + 1);
            end if;
            wr_gray_s1 <= wr_gray;
            wr_gray_s2 <= wr_gray_s1;
        end if;
    end process;

    empty_i <= '1' when wr_gray_s2 = rd_gray else '0';
    empty   <= empty_i;

    rd_level <= from_gray(wr_gray_s2) - rd_bin;
    wr_level <= wr_bin - from_gray(rd_gray_s2);

end Behavioral;
