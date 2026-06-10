library ieee;
use ieee.std_logic_1164.all;

entity tick_1s is
    generic (
        CLK_FREQ_HZ : positive := 100_000_000
    );
    port (
        clk  : in  std_logic;
        rst  : in  std_logic;
        tick : out std_logic
    );
end entity;

architecture rtl of tick_1s is
    signal contador : natural range 0 to CLK_FREQ_HZ - 1 := 0;
begin
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                contador <= 0;
                tick <= '0';
            elsif contador = CLK_FREQ_HZ - 1 then
                contador <= 0;
                tick <= '1';
            else
                contador <= contador + 1;
                tick <= '0';
            end if;
        end if;
    end process;
end architecture;
