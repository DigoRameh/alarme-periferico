library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_packet_rx is
    port (
        clk                     : in  std_logic;
        rst                     : in  std_logic;

        rx_data                 : in  std_logic_vector(7 downto 0);
        rx_valid                : in  std_logic;

        zonas_uart              : out std_logic_vector(4 downto 0);
        zonas_valid             : out std_logic;

        esp_heartbeat           : out std_logic;
        esp_alert_sent_ok       : out std_logic;
        esp_alert_sent_ok_pulse : out std_logic;
        esp_wifi_ok             : out std_logic;

        cmd_armar               : out std_logic;
        cmd_desarmar            : out std_logic;
        cmd_reset               : out std_logic
    );
end entity;

architecture rtl of uart_packet_rx is

    constant START_BYTE : std_logic_vector(7 downto 0) := x"A5";
    constant TYPE_ZONES : std_logic_vector(7 downto 0) := x"10";
    constant TYPE_CMD   : std_logic_vector(7 downto 0) := x"11";

    type state_t is (
        WAIT_START,
        READ_TYPE,
        READ_DATA0,
        READ_DATA1,
        READ_CHECKSUM
    );

    signal state : state_t := WAIT_START;

    signal type_reg : std_logic_vector(7 downto 0) := (others => '0');
    signal data0_reg : std_logic_vector(7 downto 0) := (others => '0');
    signal data1_reg : std_logic_vector(7 downto 0) := (others => '0');

    signal zonas_reg : std_logic_vector(4 downto 0) := (others => '0');

    signal heartbeat_reg     : std_logic := '0';
    signal alert_ok_reg      : std_logic := '0';
    signal wifi_ok_reg       : std_logic := '0';

begin

    zonas_uart        <= zonas_reg;
    esp_heartbeat     <= heartbeat_reg;
    esp_alert_sent_ok <= alert_ok_reg;
    esp_wifi_ok       <= wifi_ok_reg;

    process(clk)
        variable checksum_calc : std_logic_vector(7 downto 0);
    begin
        if rising_edge(clk) then

            zonas_valid             <= '0';
            esp_alert_sent_ok_pulse <= '0';
            cmd_armar               <= '0';
            cmd_desarmar            <= '0';
            cmd_reset               <= '0';

            if rst = '1' then
                state         <= WAIT_START;
                type_reg      <= (others => '0');
                data0_reg     <= (others => '0');
                data1_reg     <= (others => '0');
                zonas_reg     <= (others => '0');
                heartbeat_reg <= '0';
                alert_ok_reg  <= '0';
                wifi_ok_reg   <= '0';

            elsif rx_valid = '1' then

                case state is

                    when WAIT_START =>
                        if rx_data = START_BYTE then
                            state <= READ_TYPE;
                        end if;

                    when READ_TYPE =>
                        type_reg <= rx_data;
                        state <= READ_DATA0;

                    when READ_DATA0 =>
                        data0_reg <= rx_data;
                        state <= READ_DATA1;

                    when READ_DATA1 =>
                        data1_reg <= rx_data;
                        state <= READ_CHECKSUM;

                    when READ_CHECKSUM =>
                        checksum_calc := START_BYTE xor type_reg xor data0_reg xor data1_reg;

                        if rx_data = checksum_calc then

                            ------------------------------------------------------------------
                            -- Pacote 0x10: ESP32 -> FPGA
                            -- 0xA5 | 0x10 | ZONES | FLAGS | CHECKSUM
                            ------------------------------------------------------------------
                            if type_reg = TYPE_ZONES then

                                zonas_reg <= data0_reg(4 downto 0);
                                zonas_valid <= '1';

                                heartbeat_reg <= data1_reg(0);
                                alert_ok_reg  <= data1_reg(1);
                                wifi_ok_reg   <= data1_reg(2);

                                if data1_reg(1) = '1' then
                                    esp_alert_sent_ok_pulse <= '1';
                                end if;

                            ------------------------------------------------------------------
                            -- Pacote opcional 0x11: comando remoto
                            -- 0xA5 | 0x11 | CMD | 0x00 | CHECKSUM
                            ------------------------------------------------------------------
                            elsif type_reg = TYPE_CMD then

                                if data0_reg = x"01" then
                                    cmd_armar <= '1';

                                elsif data0_reg = x"02" then
                                    cmd_desarmar <= '1';

                                elsif data0_reg = x"03" then
                                    cmd_reset <= '1';
                                end if;

                            end if;
                        end if;

                        state <= WAIT_START;

                end case;
            end if;
        end if;
    end process;

end architecture;