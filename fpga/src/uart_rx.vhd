library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_rx is
    generic (
        CLK_FREQ_HZ : positive := 100_000_000;
        BAUD_RATE   : positive := 115200
    );
    port (
        clk      : in  std_logic;
        rst      : in  std_logic;
        rx       : in  std_logic;
        rx_data  : out std_logic_vector(7 downto 0);
        rx_valid : out std_logic;
        rx_error : out std_logic
    );
end entity;

architecture rtl of uart_rx is

    constant CLKS_PER_BIT : positive := CLK_FREQ_HZ / BAUD_RATE;

    type state_t is (
        IDLE,
        START_BIT,
        DATA_BITS,
        STOP_BIT
    );

    signal state     : state_t := IDLE;
    signal clk_count : natural range 0 to CLKS_PER_BIT - 1 := 0;
    signal bit_index : natural range 0 to 7 := 0;

    signal rx_sync_0 : std_logic := '1';
    signal rx_sync_1 : std_logic := '1';

    signal data_reg  : std_logic_vector(7 downto 0) := (others => '0');
    signal valid_reg : std_logic := '0';
    signal error_reg : std_logic := '0';

begin

    rx_data  <= data_reg;
    rx_valid <= valid_reg;
    rx_error <= error_reg;

    --------------------------------------------------------------------------
    -- Sincronizacao da entrada RX.
    --------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            rx_sync_0 <= rx;
            rx_sync_1 <= rx_sync_0;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- Receptor UART 8N1.
    --------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then

            valid_reg <= '0';
            error_reg <= '0';

            if rst = '1' then
                state     <= IDLE;
                clk_count <= 0;
                bit_index <= 0;
                data_reg  <= (others => '0');

            else
                case state is

                    when IDLE =>
                        clk_count <= 0;
                        bit_index <= 0;

                        if rx_sync_1 = '0' then
                            state <= START_BIT;
                        end if;

                    when START_BIT =>
                        if clk_count = (CLKS_PER_BIT / 2) then
                            if rx_sync_1 = '0' then
                                clk_count <= 0;
                                state <= DATA_BITS;
                            else
                                state <= IDLE;
                            end if;
                        else
                            clk_count <= clk_count + 1;
                        end if;

                    when DATA_BITS =>
                        if clk_count = CLKS_PER_BIT - 1 then
                            clk_count <= 0;
                            data_reg(bit_index) <= rx_sync_1;

                            if bit_index = 7 then
                                bit_index <= 0;
                                state <= STOP_BIT;
                            else
                                bit_index <= bit_index + 1;
                            end if;
                        else
                            clk_count <= clk_count + 1;
                        end if;

                    when STOP_BIT =>
                        if clk_count = CLKS_PER_BIT - 1 then
                            clk_count <= 0;

                            if rx_sync_1 = '1' then
                                valid_reg <= '1';
                            else
                                error_reg <= '1';
                            end if;

                            state <= IDLE;
                        else
                            clk_count <= clk_count + 1;
                        end if;

                end case;
            end if;
        end if;
    end process;

end architecture;