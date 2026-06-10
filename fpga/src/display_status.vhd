library ieee;
use ieee.std_logic_1164.all;

entity display_status is
    port (
        status_code : in  std_logic_vector(1 downto 0); -- 00=d, 01=A, 10=U
        seg         : out std_logic_vector(6 downto 0); -- gfedcba; ativo em 0
        an          : out std_logic_vector(3 downto 0);
        dp          : out std_logic
    );
end entity;

architecture rtl of display_status is
begin
    process(status_code)
    begin
        case status_code is
            when "00" => seg <= "0100001"; -- d
            when "01" => seg <= "0001000"; -- A
            when "10" => seg <= "1000001"; -- U
            when others => seg <= "1111111"; -- apagado
        end case;
    end process;

    an <= "1110"; -- apenas o dígito da direita habilitado
    dp <= '1';    -- ponto decimal desligado
end architecture;
