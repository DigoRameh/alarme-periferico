library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_tx is
    generic (
        CLK_FREQ_HZ : positive := 100_000_000;
        BAUD_RATE   : positive := 115200
    );
    port (
        clk      : in  std_logic;
        rst      : in  std_logic;
        tx_start : in  std_logic;
        tx_data  : in  std_logic_vector(7 downto 0);
        tx       : out std_logic;
        tx_busy  : out std_logic
    );
end entity;

architecture rtl of uart_tx is

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

    signal data_reg  : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_reg    : std_logic := '1';
    signal busy_reg  : std_logic := '0';

begin

    tx      <= tx_reg;
    tx_busy <= busy_reg;

    process(clk)
    begin
        if rising_edge(clk) then

            if rst = '1' then
                state     <= IDLE;
                clk_count <= 0;
                bit_index <= 0;
                data_reg  <= (others => '0');
                tx_reg    <= '1';
                busy_reg  <= '0';

            else
                case state is

                    when IDLE =>
                        tx_reg   <= '1';
                        busy_reg <= '0';

                        if tx_start = '1' then
                            data_reg  <= tx_data;
                            clk_count <= 0;
                            bit_index <= 0;
                            busy_reg  <= '1';
                            state     <= START_BIT;
                        end if;

                    when START_BIT =>
                        tx_reg <= '0';
                        busy_reg <= '1';

                        if clk_count = CLKS_PER_BIT - 1 then
                            clk_count <= 0;
                            state <= DATA_BITS;
                        else
                            clk_count <= clk_count + 1;
                        end if;

                    when DATA_BITS =>
                        tx_reg <= data_reg(bit_index);
                        busy_reg <= '1';

                        if clk_count = CLKS_PER_BIT - 1 then
                            clk_count <= 0;

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
                        tx_reg <= '1';
                        busy_reg <= '1';

                        if clk_count = CLKS_PER_BIT - 1 then
                            clk_count <= 0;
                            state <= IDLE;
                        else
                            clk_count <= clk_count + 1;
                        end if;

                end case;
            end if;
        end if;
    end process;

end architecture;