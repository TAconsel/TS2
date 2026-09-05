library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- 8N1 UART transmitter.
--
-- DIVISOR is clk cycles per bit: clk_hz / baud.  The board's CH340 sits on
-- FPGA_RX / FPGA_TX (PIN_10 / PIN_11) and appears as /dev/ttyUSB0 on the host,
-- which is the only way to get a continuous trace out of the design -- JTAG
-- Sources and Probes can only sample.
--
-- Runs from the 50 MHz reference rather than the ULPI clock on purpose: if the
-- USB PHY is not clocking, the trace has to still come out and say so.

entity uart_tx is
    Generic (
        DIVISOR : natural := 50   -- 50 MHz / 1 Mbaud
    );
    Port (
        clk   : in  STD_LOGIC;
        -- Byte to send, accepted on any cycle where valid and ready are both
        -- high.
        data  : in  STD_LOGIC_VECTOR(7 downto 0);
        valid : in  STD_LOGIC;
        ready : out STD_LOGIC;
        tx    : out STD_LOGIC
    );
end uart_tx;

architecture Behavioral of uart_tx is

    -- Start bit, 8 data bits, stop bit; shifted out LSB first.  The register
    -- is filled with ones above the payload so that once the frame has been
    -- shifted through, the line is left idle high.
    signal shreg   : STD_LOGIC_VECTOR(9 downto 0) := (others => '1');
    signal bit_cnt : unsigned(3 downto 0) := (others => '0');
    signal div_cnt : unsigned(15 downto 0) := (others => '0');
    signal busy    : STD_LOGIC := '0';

begin

    ready <= not busy;
    tx    <= shreg(0);

    process(clk)
    begin
        if rising_edge(clk) then
            if busy = '0' then
                if valid = '1' then
                    shreg   <= '1' & data & '0';
                    bit_cnt <= to_unsigned(10, bit_cnt'length);
                    div_cnt <= to_unsigned(DIVISOR - 1, div_cnt'length);
                    busy    <= '1';
                end if;
            else
                if div_cnt = 0 then
                    div_cnt <= to_unsigned(DIVISOR - 1, div_cnt'length);
                    shreg   <= '1' & shreg(9 downto 1);
                    bit_cnt <= bit_cnt - 1;
                    if bit_cnt = 1 then
                        busy <= '0';
                    end if;
                else
                    div_cnt <= div_cnt - 1;
                end if;
            end if;
        end if;
    end process;

end Behavioral;
