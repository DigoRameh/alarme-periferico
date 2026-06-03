library ieee;
use ieee.std_logic_1164.all;

entity sync_vector is
    generic (WIDTH : positive := 5);
    port (
        clk      : in  std_logic;
        async_in : in  std_logic_vector(WIDTH - 1 downto 0);
        sync_out : out std_logic_vector(WIDTH - 1 downto 0)
    );
end entity;

architecture rtl of sync_vector is
    signal meta : std_logic_vector(WIDTH - 1 downto 0) := (others => '0');
    signal sync : std_logic_vector(WIDTH - 1 downto 0) := (others => '0');
begin
    process(clk)
    begin
        if rising_edge(clk) then
            meta <= async_in;
            sync <= meta;
        end if;
    end process;
    sync_out <= sync;
end architecture;
