library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity led_blink is
    Port (
        clk : in  STD_LOGIC;  -- 50 MHz clock
        led : out STD_LOGIC
    );
end led_blink;

architecture Behavioral of led_blink is

    -- 25,000,000 clock cycles = 0.5 seconds at 50 MHz
    constant MAX_COUNT : unsigned(24 downto 0) :=
                         to_unsigned(24999999, 25);

    signal counter : unsigned(24 downto 0) := (others => '0');
    signal led_reg : STD_LOGIC := '0';

begin

    process(clk)
    begin
        if rising_edge(clk) then

            if counter = MAX_COUNT then
                counter <= (others => '0');
                led_reg <= not led_reg;
            else
                counter <= counter + 1;
            end if;

        end if;
    end process;

    led <= led_reg;

end Behavioral;
