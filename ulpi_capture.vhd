library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- A logic analyser for the ULPI bus, one sample per 60 MHz clock.
--
-- Simulation against a spec-behaving PHY model only proves the link obeys the
-- spec.  When the real part disagrees -- and this one does, returning bytes
-- that belong to earlier transfers -- the only way forward is to see what is
-- actually on the wire, cycle by cycle.  The JTAG source/probe interface can
-- only sample, so the trace goes out over the UART instead.
--
-- The two line-state bits of an RX CMD are masked out before the comparison.
-- The PHY reports every J-to-K transition on the wire, which during a packet
-- is one report per bit, and those alone would fill the buffer several times
-- over during a single control transfer.  Masking them collapses the run into
-- one entry per change of receive state, which is the part worth seeing.
--
-- Samples are recorded only when the bus changes, together with how many
-- cycles the previous state lasted.  Raw cycle-by-cycle capture is hopeless
-- for full-speed USB, where a byte occupies 40 clocks and a single control
-- transfer runs for tens of microseconds: almost every sample would be a
-- repeat.  Recording transitions instead turns a whole transaction into a few
-- dozen entries while keeping the timing, which is what makes inter-packet
-- gaps and turnaround delays visible.
--
-- The trigger is a chosen byte arriving from the PHY with NXT asserted.  It
-- defaults to the SETUP PID, because start-of-frame tokens arrive a thousand
-- times a second and would otherwise fill the buffer with the one packet that
-- is never interesting.
--
-- The buffer is a true dual-port memory: written in the ULPI domain, read out
-- in the reference domain, which matters because the whole point is to be
-- able to read it after the PHY has stopped clocking.

entity ulpi_capture is
    Generic (
        ADDR_BITS : natural := 10;
        -- 0x2D is a SETUP token's PID with its check nibble.
        TRIGGER   : STD_LOGIC_VECTOR(7 downto 0) := x"2D"
    );
    Port (
        clk  : in STD_LOGIC;                        -- 60 MHz ULPI clock
        -- Held low to keep the buffer armed and empty; released to let it
        -- trigger.  Nothing re-arms it afterwards: one shot per reset, so the
        -- capture is always of the first thing that happened.
        arm  : in STD_LOGIC;
        d    : in STD_LOGIC_VECTOR(7 downto 0);     -- the bus itself
        dir  : in STD_LOGIC;
        nxt  : in STD_LOGIC;
        stp  : in STD_LOGIC;
        oe   : in STD_LOGIC;                        -- link is driving

        -- Readout, in the reference domain.  rd_data is registered.
        rd_clk  : in  STD_LOGIC;
        rd_addr : in  unsigned(ADDR_BITS-1 downto 0);
        rd_data : out STD_LOGIC_VECTOR(31 downto 0);
        full    : out STD_LOGIC
    );
end ulpi_capture;

architecture Behavioral of ulpi_capture is

    constant DEPTH : integer := 2**ADDR_BITS;

    type ram_t is array (0 to DEPTH - 1) of STD_LOGIC_VECTOR(31 downto 0);
    signal ram : ram_t;

    signal wr_addr : unsigned(ADDR_BITS-1 downto 0) := (others => '0');
    signal running : STD_LOGIC := '0';
    signal done    : STD_LOGIC := '0';
    signal sample  : STD_LOGIC_VECTOR(11 downto 0);
    signal masked  : STD_LOGIC_VECTOR(7 downto 0);
    signal last    : STD_LOGIC_VECTOR(11 downto 0) := (others => '0');
    signal dwell   : unsigned(15 downto 0) := (others => '0');
    signal primed  : STD_LOGIC := '0';

    signal done_s1, done_s2 : STD_LOGIC := '0';

begin

    -- The bus plus the control lines; oe says which end was driving, without
    -- which a captured byte cannot be attributed.  An RX CMD -- the PHY
    -- driving with NXT low -- keeps only its receive and VBUS status.
    masked <= d(7 downto 2) & "00" when (dir = '1' and nxt = '0') else d;
    sample <= oe & stp & nxt & dir & masked;

    process(clk)
    begin
        if rising_edge(clk) then
            if arm = '0' then
                wr_addr <= (others => '0');
                running <= '0';
                done    <= '0';
                primed  <= '0';
                dwell   <= (others => '0');
            else
                if running = '0' and done = '0' then
                    -- Trigger on the PHY handing over a received byte, which
                    -- is the first byte of a USB packet.
                    if dir = '1' and nxt = '1' and d = TRIGGER then
                        running <= '1';
                        primed  <= '0';
                        dwell   <= (others => '0');
                    end if;
                end if;

                if running = '1' then
                    if sample /= last or dwell = 65535 then
                        -- Close out the previous state and start a new one.
                        -- The very first entry has no previous state to close.
                        if primed = '1' then
                            ram(to_integer(wr_addr)) <=
                                std_logic_vector(dwell) & "0000" & last;
                            if wr_addr = DEPTH - 1 then
                                running <= '0';
                                done    <= '1';
                            else
                                wr_addr <= wr_addr + 1;
                            end if;
                        end if;
                        last   <= sample;
                        primed <= '1';
                        dwell  <= to_unsigned(1, 16);
                    else
                        dwell <= dwell + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    process(rd_clk)
    begin
        if rising_edge(rd_clk) then
            rd_data <= ram(to_integer(rd_addr));
            done_s1 <= done;
            done_s2 <= done_s1;
        end if;
    end process;

    full <= done_s2;

end Behavioral;
