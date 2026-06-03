library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_alarme_controlador is
end entity;

architecture sim of tb_alarme_controlador is
    constant CLK_PERIOD : time := 10 ns;

    signal clk              : std_logic := '0';
    signal rst              : std_logic := '0';
    signal tick_1s          : std_logic := '0';
    signal arm_toggle_pulse : std_logic := '0';
    signal ack_esp32_pulse  : std_logic := '0';
    signal zones_in         : std_logic_vector(4 downto 0) := (others => '0');
    signal delay_seconds_in : unsigned(6 downto 0) := to_unsigned(2, 7);
    signal zones_latched_o  : std_logic_vector(4 downto 0);
    signal status_code_o    : std_logic_vector(1 downto 0);
    signal armado_o         : std_logic;
    signal disparando_o     : std_logic;
    signal sirene_o         : std_logic;
    signal fumaca_o         : std_logic;
    signal cerca_simulada_o : std_logic;
    signal sinal_esp32_o    : std_logic;
    signal reset_esp32_o    : std_logic;

    procedure pulse(signal p : out std_logic) is
    begin
        p <= '1';
        wait until rising_edge(clk);
        p <= '0';
        wait until rising_edge(clk);
    end procedure;

    procedure tick_second(signal t : out std_logic) is
    begin
        t <= '1';
        wait until rising_edge(clk);
        t <= '0';
        wait until rising_edge(clk);
    end procedure;
begin
    clk <= not clk after CLK_PERIOD / 2;

    DUT : entity work.alarme_controlador
        generic map (
            VALIDATION_SECONDS => 1,
            WATCHDOG_SECONDS   => 2
        )
        port map (
            clk              => clk,
            rst              => rst,
            tick_1s          => tick_1s,
            arm_toggle_pulse => arm_toggle_pulse,
            ack_esp32_pulse  => ack_esp32_pulse,
            zones_in         => zones_in,
            delay_seconds_in => delay_seconds_in,
            zones_latched_o  => zones_latched_o,
            status_code_o    => status_code_o,
            armado_o         => armado_o,
            disparando_o     => disparando_o,
            sirene_o         => sirene_o,
            fumaca_o         => fumaca_o,
            cerca_simulada_o => cerca_simulada_o,
            sinal_esp32_o    => sinal_esp32_o,
            reset_esp32_o    => reset_esp32_o
        );

    stimulus : process
    begin
        -- Reset inicial
        rst <= '1';
        wait for 2 * CLK_PERIOD;
        rst <= '0';
        wait until rising_edge(clk);
        wait for 1 ns;
        assert status_code_o = "00"
            report "Erro: o sistema deveria iniciar DESARMADO."
            severity error;

        -- Arma o alarme
        pulse(arm_toggle_pulse);
        wait for 1 ns;
        assert status_code_o = "01" and armado_o = '1'
            report "Erro: o sistema nao entrou no estado ARMADO."
            severity error;

        -- Viola as zonas 2 e 4
        zones_in <= "01010";
        wait until rising_edge(clk);
        tick_second(tick_1s); -- valida a violacao por 1 segundo
        wait for 1 ns;
        assert zones_latched_o = "01010"
            report "Erro: as zonas violadas nao foram registradas."
            severity error;
        assert disparando_o = '0'
            report "Erro: disparo ocorreu antes do atraso configurado."
            severity error;

        -- Atraso programado de 2 segundos
        tick_second(tick_1s);
        wait for 1 ns;
        assert disparando_o = '0'
            report "Erro: disparo antecipado durante a contagem."
            severity error;

        tick_second(tick_1s);
        wait for 1 ns;
        assert disparando_o = '1' and sinal_esp32_o = '1'
            report "Erro: o disparo nao foi ativado apos o tempo configurado."
            severity error;
        assert sirene_o = '1' and fumaca_o = '1' and cerca_simulada_o = '1'
            report "Erro: saidas logicas das contramedidas nao foram ativadas."
            severity error;

        -- Recebe ACK do ESP32: watchdog nao deve resetar
        pulse(ack_esp32_pulse);
        tick_second(tick_1s);
        tick_second(tick_1s);
        tick_second(tick_1s);
        wait for 1 ns;
        assert reset_esp32_o = '0'
            report "Erro: reset de comunicacao ocorreu mesmo com ACK."
            severity error;

        -- Desarma e rearma para testar falha de comunicacao
        pulse(arm_toggle_pulse);
        wait for 1 ns;
        assert status_code_o = "00"
            report "Erro: sistema nao desarmou."
            severity error;

        zones_in <= (others => '0');
        pulse(arm_toggle_pulse);
        zones_in <= "00001";
        wait until rising_edge(clk);
        tick_second(tick_1s);
        tick_second(tick_1s);
        tick_second(tick_1s);
        wait for 1 ns;
        assert disparando_o = '1'
            report "Erro: segundo disparo nao ocorreu."
            severity error;

        -- Sem ACK: apos 2 segundos o controlador solicita reset do ESP32
        tick_second(tick_1s);
        tick_second(tick_1s);
        wait for 1 ns;
        assert reset_esp32_o = '1'
            report "Erro: watchdog nao acionou reset do ESP32."
            severity error;

        report "SIMULACAO FINALIZADA COM SUCESSO." severity note;
        wait;
    end process;
end architecture;
