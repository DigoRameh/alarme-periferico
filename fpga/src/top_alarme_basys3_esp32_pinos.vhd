----------------------------------------------------------------------------------
-- Projeto: Central de Alarme Perimetrico - Basys 3 + ESP32
-- Arquivo: top_alarme_basys3_esp32_pinos.vhd
--
-- Este TOP foi escrito para combinar diretamente com o arquivo pinos.txt:
--   clk, sw, led, seg, dp, an, btnC, btnU, btnR, JA e JB.
--
-- Mapeamento funcional:
--   SW(4 downto 0)  : zonas 1 a 5 simuladas
--   SW(11 downto 5) : atraso em segundos, binario (0 a 120)
--   LED(4 downto 0) : zonas registradas como violadas
--   LED(5)           : sistema armado
--   LED(6)           : sistema disparado
--   LED(7)           : comando de sirene
--   LED(8)           : comando de nevoa/atomizador seguro
--   LED(9)           : sinalizacao de contencao demonstrativa
--   LED(10)          : reset/watchdog do ESP32
--   LED(11)          : ACK recebido do ESP32 ou pelo botao de teste
--
-- Pmod JA (somente sinais logicos para drivers externos):
--   JA(0) : sirene
--   JA(1) : nevoa/atomizador seguro
--   JA(2) : sinalizacao de contencao demonstrativa
--   JA(3) : reset/enable do ESP32
--
-- Pmod JB (comunicacao FPGA <-> ESP32):
--   JB(0) : disparo        FPGA -> ESP32
--   JB(1) : armado         FPGA -> ESP32
--   JB(2) : zona 1         FPGA -> ESP32
--   JB(3) : zona 2         FPGA -> ESP32
--   JB(4) : zona 3         FPGA -> ESP32
--   JB(5) : zona 4         FPGA -> ESP32
--   JB(6) : zona 5         FPGA -> ESP32
--   JB(7) : ACK            ESP32 -> FPGA
--
-- Seguranca: JA contem apenas habilitacoes logicas de 3,3 V. Nunca conecte
-- bombas, sirenes ou cargas diretamente na placa; utilize interface/driver.
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity top_alarme_basys3_esp32_pinos is
    generic (
        CLK_FREQ_HZ : positive := 100_000_000
    );
    port (
        clk  : in    std_logic;                         -- clock W5 do pinos.txt
        sw   : in    std_logic_vector(11 downto 0);    -- SW0..SW11 usados
        led  : out   std_logic_vector(11 downto 0);   -- LED0..LED11 usados
        seg  : out   std_logic_vector(6 downto 0);
        dp   : out   std_logic;
        an   : out   std_logic_vector(3 downto 0);
        btnC : in    std_logic;                        -- arma/desarma
        btnU : in    std_logic;                        -- reset geral
        btnR : in    std_logic;                        -- ACK manual para teste
        JA   : out   std_logic_vector(3 downto 0);    -- comandos externos
        JB   : inout std_logic_vector(7 downto 0)     -- comunicacao ESP32
    );
end entity;

architecture structural of top_alarme_basys3_esp32_pinos is
    signal reset_pulse        : std_logic;
    signal arm_pulse          : std_logic;
    signal ack_manual_pulse   : std_logic;
    signal ack_esp32_pulse    : std_logic;
    signal ack_event_pulse    : std_logic;
    signal tick               : std_logic;

    signal zones_sync         : std_logic_vector(4 downto 0);
    signal zones_latched      : std_logic_vector(4 downto 0);
    signal status_code        : std_logic_vector(1 downto 0);
    signal delay_seconds      : unsigned(6 downto 0);

    signal armado             : std_logic;
    signal disparando         : std_logic;
    signal sirene             : std_logic;
    signal fumaca             : std_logic;
    signal contencao_demo     : std_logic;
    signal sinal_esp32        : std_logic;
    signal reset_esp32        : std_logic;
    signal ack_indicator      : std_logic := '0';

    constant BTN_STABLE_CYCLES : positive := CLK_FREQ_HZ / 100; -- 10 ms
begin
    ------------------------------------------------------------------------------
    -- SW5 e o bit menos significativo do tempo: SW5=1 s, SW6=2 s, ... SW11=64 s.
    -- O modulo controlador limita valores maiores que 120 para 120 segundos.
    ------------------------------------------------------------------------------
    delay_seconds <= unsigned(sw(11 downto 5));

    U_TICK : entity work.tick_1s
        generic map (
            CLK_FREQ_HZ => CLK_FREQ_HZ
        )
        port map (
            clk  => clk,
            rst  => reset_pulse,
            tick => tick
        );

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

    -- Permite testar o ACK sem conectar o ESP32.
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

    -- Entrada real de ACK enviada pelo ESP32 em JB(7).
    -- No ESP32: manter LOW e gerar pulso HIGH apos publicar o evento.
    U_ACK_ESP32 : entity work.debounce_onepulse
        generic map (
            STABLE_CYCLES => BTN_STABLE_CYCLES
        )
        port map (
            clk       => clk,
            rst       => reset_pulse,
            btn_async => JB(7),
            pulse     => ack_esp32_pulse,
            level     => open
        );

    ack_event_pulse <= ack_manual_pulse or ack_esp32_pulse;

    U_SYNC_ZONAS : entity work.sync_vector
        generic map (
            WIDTH => 5
        )
        port map (
            clk      => clk,
            async_in => sw(4 downto 0),
            sync_out => zones_sync
        );

    U_CONTROLADOR : entity work.alarme_controlador
        generic map (
            VALIDATION_SECONDS => 1
        )
        port map (
            clk              => clk,
            rst              => reset_pulse,
            tick_1s          => tick,
            arm_toggle_pulse => arm_pulse,
            ack_esp32_pulse  => ack_event_pulse,
            zones_in         => zones_sync,
            delay_seconds_in => delay_seconds,
            zones_latched_o  => zones_latched,
            status_code_o    => status_code,
            armado_o         => armado,
            disparando_o     => disparando,
            sirene_o         => sirene,
            fumaca_o         => fumaca,
            cerca_simulada_o => contencao_demo,
            sinal_esp32_o    => sinal_esp32,
            reset_esp32_o    => reset_esp32
        );

    U_DISPLAY : entity work.display_status
        port map (
            status_code => status_code,
            seg         => seg,
            an          => an,
            dp          => dp
        );

    ------------------------------------------------------------------------------
    -- Indicador de ACK: permanece ligado apos o recebimento e e limpo no reset
    -- ou ao desarmar. Facilita a demonstracao em placa.
    ------------------------------------------------------------------------------
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

    led(4 downto 0) <= zones_latched; -- zonas 1 a 5
    led(5)           <= armado;
    led(6)           <= disparando;
    led(7)           <= sirene;
    led(8)           <= fumaca;
    led(9)           <= contencao_demo;
    led(10)          <= reset_esp32;
    led(11)          <= ack_indicator;

    ------------------------------------------------------------------------------
    -- Pmod JA: apenas comandos logicos para drivers/isoladores apropriados.
    ------------------------------------------------------------------------------
    JA(0) <= sirene;
    JA(1) <= fumaca;
    JA(2) <= contencao_demo;
    JA(3) <= reset_esp32;

    ------------------------------------------------------------------------------
    -- Pmod JB: comunicacao digital com o ESP32.
    ------------------------------------------------------------------------------
    JB(0) <= sinal_esp32;
    JB(1) <= armado;
    JB(2) <= zones_latched(0);
    JB(3) <= zones_latched(1);
    JB(4) <= zones_latched(2);
    JB(5) <= zones_latched(3);
    JB(6) <= zones_latched(4);
    JB(7) <= 'Z';              -- entrada ACK; FPGA libera este pino
end architecture;
