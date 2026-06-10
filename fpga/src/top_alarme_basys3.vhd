library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity top_alarme_basys3 is
    generic (
        CLK_FREQ_HZ : positive := 100_000_000
    );
    port (
        clk  : in  std_logic;

        sw   : in  std_logic_vector(11 downto 0);
        led  : out std_logic_vector(11 downto 0);

        seg  : out std_logic_vector(6 downto 0);
        dp   : out std_logic;
        an   : out std_logic_vector(3 downto 0);

        btnC : in  std_logic; -- armar/desarmar
        btnU : in  std_logic; -- reset
        btnR : in  std_logic; -- ACK manual para teste

        -- Atuadores pelo PMOD JA
        -- JA(0): sirene
        -- JA(1): estrobo/fumaca
        -- JA(2): cerca/contencao demonstrativa
        JA   : out std_logic_vector(2 downto 0);

        -- UART com ESP32
        -- ESP32 GPIO17 TX2 -> uart_rx_esp32
        -- ESP32 GPIO16 RX2 <- uart_tx_esp32
        uart_rx_esp32 : in  std_logic;
        uart_tx_esp32 : out std_logic
    );
end entity;

architecture structural of top_alarme_basys3 is

    signal reset_pulse      : std_logic;
    signal arm_pulse        : std_logic;
    signal ack_manual_pulse : std_logic;
    signal ack_event_pulse  : std_logic;
    signal tick             : std_logic;

    signal zones_uart       : std_logic_vector(4 downto 0);
    signal zones_latched    : std_logic_vector(4 downto 0);

    signal status_code      : std_logic_vector(1 downto 0);
    signal delay_seconds    : unsigned(6 downto 0);

    signal armado           : std_logic;
    signal disparando       : std_logic;
    signal sirene           : std_logic;
    signal estrobo          : std_logic;
    signal contencao_demo   : std_logic;
    signal sinal_esp32      : std_logic;
    signal reset_esp32      : std_logic;

    signal ack_indicator    : std_logic := '0';

    constant BTN_STABLE_CYCLES : positive := CLK_FREQ_HZ / 100;

    --------------------------------------------------------------------------
    -- UART RX/TX byte-level
    --------------------------------------------------------------------------
    signal uart_rx_data      : std_logic_vector(7 downto 0);
    signal uart_rx_valid     : std_logic;
    signal uart_rx_error     : std_logic;

    signal uart_tx_start     : std_logic;
    signal uart_tx_data      : std_logic_vector(7 downto 0);
    signal uart_tx_busy      : std_logic;

    --------------------------------------------------------------------------
    -- Pacote recebido do ESP32
    --------------------------------------------------------------------------
    signal zonas_valid_uart           : std_logic;
    signal esp_heartbeat              : std_logic;
    signal esp_alert_sent_ok          : std_logic;
    signal esp_alert_sent_ok_pulse    : std_logic;
    signal esp_wifi_ok                : std_logic;
    signal cmd_armar_uart             : std_logic;
    signal cmd_desarmar_uart          : std_logic;
    signal cmd_reset_uart             : std_logic;

    --------------------------------------------------------------------------
    -- Watchdog de comunicacao ESP32
    -- Se ficar mais de 2 segundos sem pacote valido 0x10, gera erro.
    --------------------------------------------------------------------------
    constant ESP_TIMEOUT_CYCLES : natural := CLK_FREQ_HZ * 2;

    signal esp_timeout_counter : natural range 0 to ESP_TIMEOUT_CYCLES := 0;
    signal esp32_timeout       : std_logic := '1';

    --------------------------------------------------------------------------
    -- Status enviado para o ESP32
    --------------------------------------------------------------------------
    signal status_uart : std_logic_vector(7 downto 0);

begin

    --------------------------------------------------------------------------
    -- Delay de disparo configurado pelos switches SW5 ate SW11.
    -- SW0 ate SW4 nao sao mais sensores. Agora as zonas vem do ESP32 via UART.
    --------------------------------------------------------------------------
    delay_seconds <= unsigned(sw(11 downto 5));

    --------------------------------------------------------------------------
    -- Gerador de tick de 1 segundo.
    --------------------------------------------------------------------------
    U_TICK : entity work.tick_1s
        generic map (
            CLK_FREQ_HZ => CLK_FREQ_HZ
        )
        port map (
            clk  => clk,
            rst  => reset_pulse,
            tick => tick
        );

    --------------------------------------------------------------------------
    -- Botao de reset.
    --------------------------------------------------------------------------
    U_BTN_RESET : entity work.debounce_onepulse
        generic map (
            STABLE_CYCLES => BTN_STABLE_CYCLES
        )
        port map (
            clk       => clk,
            rst       => '0',
            btn_async => btnU,
            pulse     => reset_pulse,
            level     => open
        );

    --------------------------------------------------------------------------
    -- Botao de armar/desarmar.
    --------------------------------------------------------------------------
    U_BTN_ARMAR : entity work.debounce_onepulse
        generic map (
            STABLE_CYCLES => BTN_STABLE_CYCLES
        )
        port map (
            clk       => clk,
            rst       => reset_pulse,
            btn_async => btnC,
            pulse     => arm_pulse,
            level     => open
        );

    --------------------------------------------------------------------------
    -- ACK manual para teste usando btnR.
    --------------------------------------------------------------------------
    U_BTN_ACK_MANUAL : entity work.debounce_onepulse
        generic map (
            STABLE_CYCLES => BTN_STABLE_CYCLES
        )
        port map (
            clk       => clk,
            rst       => reset_pulse,
            btn_async => btnR,
            pulse     => ack_manual_pulse,
            level     => open
        );

    --------------------------------------------------------------------------
    -- UART RX: recebe bytes do ESP32.
    --------------------------------------------------------------------------
    U_UART_RX : entity work.uart_rx
        generic map (
            CLK_FREQ_HZ => CLK_FREQ_HZ,
            BAUD_RATE   => 115200
        )
        port map (
            clk      => clk,
            rst      => reset_pulse,
            rx       => uart_rx_esp32,
            rx_data  => uart_rx_data,
            rx_valid => uart_rx_valid,
            rx_error => uart_rx_error
        );

    --------------------------------------------------------------------------
    -- Parser dos pacotes recebidos do ESP32.
    -- Recebe:
    -- 0xA5 | 0x10 | ZONES | FLAGS | CHECKSUM
    --------------------------------------------------------------------------
    U_PACKET_RX : entity work.uart_packet_rx
        port map (
            clk                     => clk,
            rst                     => reset_pulse,

            rx_data                 => uart_rx_data,
            rx_valid                => uart_rx_valid,

            zonas_uart              => zones_uart,
            zonas_valid             => zonas_valid_uart,

            esp_heartbeat           => esp_heartbeat,
            esp_alert_sent_ok       => esp_alert_sent_ok,
            esp_alert_sent_ok_pulse => esp_alert_sent_ok_pulse,
            esp_wifi_ok             => esp_wifi_ok,

            cmd_armar               => cmd_armar_uart,
            cmd_desarmar            => cmd_desarmar_uart,
            cmd_reset               => cmd_reset_uart
        );

    --------------------------------------------------------------------------
    -- Watchdog de comunicacao do ESP32.
    --------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset_pulse = '1' then
                esp_timeout_counter <= 0;
                esp32_timeout       <= '1';

            elsif zonas_valid_uart = '1' then
                esp_timeout_counter <= 0;
                esp32_timeout       <= '0';

            elsif esp_timeout_counter = ESP_TIMEOUT_CYCLES then
                esp32_timeout <= '1';

            else
                esp_timeout_counter <= esp_timeout_counter + 1;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- ACK para o controlador:
    -- btnR = ACK manual
    -- esp_alert_sent_ok_pulse = ESP32 informou que alerta foi enviado
    --------------------------------------------------------------------------
    ack_event_pulse <= ack_manual_pulse or esp_alert_sent_ok_pulse;

    --------------------------------------------------------------------------
    -- Controlador principal do alarme.
    -- Agora zones_in vem do ESP32 via UART.
    --------------------------------------------------------------------------
    U_CONTROLADOR : entity work.alarme_controlador
        generic map (
            VALIDATION_SECONDS => 1,
            WATCHDOG_SECONDS   => 5
        )
        port map (
            clk              => clk,
            rst              => reset_pulse,
            tick_1s          => tick,

            arm_toggle_pulse => arm_pulse,
            ack_esp32_pulse  => ack_event_pulse,

            zones_in         => zones_uart,
            delay_seconds_in => delay_seconds,

            zones_latched_o  => zones_latched,
            status_code_o    => status_code,

            armado_o         => armado,
            disparando_o     => disparando,
            sirene_o         => sirene,
            fumaca_o         => estrobo,
            cerca_simulada_o => contencao_demo,
            sinal_esp32_o    => sinal_esp32,
            reset_esp32_o    => reset_esp32
        );

    --------------------------------------------------------------------------
    -- Display de sete segmentos.
    --------------------------------------------------------------------------
    U_DISPLAY : entity work.display_status
        port map (
            status_code => status_code,
            seg         => seg,
            an          => an,
            dp          => dp
        );

    --------------------------------------------------------------------------
    -- LED11 indica que a FPGA recebeu ACK do ESP32 ou ACK manual.
    --------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset_pulse = '1' or armado = '0' then
                ack_indicator <= '0';
            elsif ack_event_pulse = '1' then
                ack_indicator <= '1';
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- Monta STATUS para enviar ao ESP32.
    --
    -- bit 0 = armado
    -- bit 1 = disparando
    -- bit 2 = sirene ligada
    -- bit 3 = estrobo ligado
    -- bit 4 = cerca habilitada
    -- bit 5 = erro/comunicacao ESP32 perdida
    --------------------------------------------------------------------------
    status_uart(0) <= armado;
    status_uart(1) <= disparando;
    status_uart(2) <= sirene;
    status_uart(3) <= estrobo;
    status_uart(4) <= contencao_demo;
    status_uart(5) <= esp32_timeout;
    status_uart(6) <= '0';
    status_uart(7) <= '0';

    --------------------------------------------------------------------------
    -- UART TX: envia bytes para o ESP32.
    --------------------------------------------------------------------------
    U_UART_TX : entity work.uart_tx
        generic map (
            CLK_FREQ_HZ => CLK_FREQ_HZ,
            BAUD_RATE   => 115200
        )
        port map (
            clk      => clk,
            rst      => reset_pulse,
            tx_start => uart_tx_start,
            tx_data  => uart_tx_data,
            tx       => uart_tx_esp32,
            tx_busy  => uart_tx_busy
        );

    --------------------------------------------------------------------------
    -- Monta e transmite:
    -- 0xA5 | 0x20 | STATUS | ZONES_LATCHED | CHECKSUM
    --------------------------------------------------------------------------
    U_PACKET_TX : entity work.uart_packet_tx
        generic map (
            CLK_FREQ_HZ       => CLK_FREQ_HZ,
            SEND_INTERVAL_MS  => 200
        )
        port map (
            clk           => clk,
            rst           => reset_pulse,

            status_in     => status_uart,
            zones_latched => zones_latched,

            tx_busy       => uart_tx_busy,
            tx_start      => uart_tx_start,
            tx_data       => uart_tx_data
        );

    --------------------------------------------------------------------------
    -- LEDs da Basys.
    --------------------------------------------------------------------------
    led(4 downto 0) <= zones_latched;
    led(5)          <= armado;
    led(6)          <= disparando;
    led(7)          <= sirene;
    led(8)          <= estrobo;
    led(9)          <= contencao_demo;
    led(10)         <= esp32_timeout or reset_esp32;
    led(11)         <= ack_indicator;

    --------------------------------------------------------------------------
    -- Saidas para atuadores pelo Pmod JA.
    --------------------------------------------------------------------------
    JA(0) <= sirene;
    JA(1) <= estrobo;
    JA(2) <= contencao_demo;

end architecture;