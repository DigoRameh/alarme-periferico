library ieee;
use ieee.std_logic_1164.all;

entity debounce_onepulse is
    generic (STABLE_CYCLES : positive := 1_000_000);
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;
        btn_async : in  std_logic;
        pulse     : out std_logic;
        level     : out std_logic
    );
end entity;

architecture rtl of debounce_onepulse is
    signal sync_0       : std_logic := '0';
    signal sync_1       : std_logic := '0';
    signal stable_level : std_logic := '0';
    signal count        : natural range 0 to STABLE_CYCLES := 0;
begin
    process(clk)
    begin
        if rising_edge(clk) then
            sync_0 <= btn_async;
            sync_1 <= sync_0;
            pulse <= '0';
            if rst = '1' then
                stable_level <= '0';
                count <= 0;
            elsif sync_1 = stable_level then
                count <= 0;
            elsif count = STABLE_CYCLES - 1 then
                stable_level <= sync_1;
                count <= 0;
                if sync_1 = '1' then
                    pulse <= '1';
                end if;
            else
                count <= count + 1;
            end if;
        end if;
    end process;
    level <= stable_level;
end architecture;
