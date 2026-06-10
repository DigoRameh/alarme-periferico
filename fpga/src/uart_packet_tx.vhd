library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_packet_tx is
    generic (
        CLK_FREQ_HZ      : positive := 100_000_000;
        SEND_INTERVAL_MS : positive := 200
    );
    port (
        clk           : in  std_logic;
        rst           : in  std_logic;

        status_in     : in  std_logic_vector(7 downto 0);
        zones_latched : in  std_logic_vector(4 downto 0);

        tx_busy       : in  std_logic;
        tx_start      : out std_logic;
        tx_data       : out std_logic_vector(7 downto 0)
    );
end entity;

architecture rtl of uart_packet_tx is

    constant START_BYTE : std_logic_vector(7 downto 0) := x"A5";
    constant TYPE_STATUS : std_logic_vector(7 downto 0) := x"20";

    constant SEND_INTERVAL_CYCLES : natural := (CLK_FREQ_HZ / 1000) * SEND_INTERVAL_MS;

    type state_t is (
        IDLE,
        LOAD_BYTE,
        WAIT_BUSY_HIGH,
        WAIT_BUSY_LOW
    );

    type packet_t is array (0 to 4) of std_logic_vector(7 downto 0);

    signal state : state_t := IDLE;

    signal send_counter : natural range 0 to SEND_INTERVAL_CYCLES := 0;
    signal byte_index   : natural range 0 to 4 := 0;

    signal packet : packet_t := (others => (others => '0'));

    signal tx_start_reg : std_logic := '0';
    signal tx_data_reg  : std_logic_vector(7 downto 0) := (others => '0');

begin

    tx_start <= tx_start_reg;
    tx_data  <= tx_data_reg;

    process(clk)
        variable zones_byte : std_logic_vector(7 downto 0);
        variable checksum   : std_logic_vector(7 downto 0);
    begin
        if rising_edge(clk) then

            tx_start_reg <= '0';

            if rst = '1' then
                state        <= IDLE;
                send_counter <= 0;
                byte_index   <= 0;
                packet       <= (others => (others => '0'));
                tx_data_reg  <= (others => '0');

            else
                case state is

                    when IDLE =>

                        if send_counter = SEND_INTERVAL_CYCLES then
                            send_counter <= 0;

                            zones_byte := "000" & zones_latched;
                            checksum := START_BYTE xor TYPE_STATUS xor status_in xor zones_byte;

                            packet(0) <= START_BYTE;
                            packet(1) <= TYPE_STATUS;
                            packet(2) <= status_in;
                            packet(3) <= zones_byte;
                            packet(4) <= checksum;

                            byte_index <= 0;
                            state <= LOAD_BYTE;

                        else
                            send_counter <= send_counter + 1;
                        end if;

                    when LOAD_BYTE =>
                        if tx_busy = '0' then
                            tx_data_reg <= packet(byte_index);
                            tx_start_reg <= '1';
                            state <= WAIT_BUSY_HIGH;
                        end if;

                    when WAIT_BUSY_HIGH =>
                        if tx_busy = '1' then
                            state <= WAIT_BUSY_LOW;
                        end if;

                    when WAIT_BUSY_LOW =>
                        if tx_busy = '0' then
                            if byte_index = 4 then
                                byte_index <= 0;
                                state <= IDLE;
                            else
                                byte_index <= byte_index + 1;
                                state <= LOAD_BYTE;
                            end if;
                        end if;

                end case;
            end if;
        end if;
    end process;

end architecture;