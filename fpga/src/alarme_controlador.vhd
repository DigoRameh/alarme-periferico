----------------------------------------------------------------------------------
-- Projeto: Central de Alarme Perimetrico - Basys 3 + ESP32
-- Arquivo: alarme_controlador.vhd
--
-- Estados:
--   DESARMADO          : sistema inativo
--   ARMADO             : monitorando as zonas
--   VALIDANDO          : valida a violacao para evitar falso-positivo
--   ATRASO             : aguarda tempo programado pelo usuario
--   DISPARADO          : ativa atuadores e comunica o ESP32
--   RESET_COMUNICACAO  : solicita reset do ESP32 se nao houver ACK
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity alarme_controlador is
    generic (
        VALIDATION_SECONDS : positive := 1;
        WATCHDOG_SECONDS   : positive := 5
    );
    port (
        clk              : in  std_logic;
        rst              : in  std_logic;
        tick_1s          : in  std_logic;
        arm_toggle_pulse : in  std_logic;
        ack_esp32_pulse  : in  std_logic;
        zones_in         : in  std_logic_vector(4 downto 0);
        delay_seconds_in : in  unsigned(6 downto 0);

        zones_latched_o  : out std_logic_vector(4 downto 0);
        status_code_o    : out std_logic_vector(1 downto 0);
        armado_o         : out std_logic;
        disparando_o     : out std_logic;
        sirene_o         : out std_logic;
        fumaca_o         : out std_logic;
        cerca_simulada_o : out std_logic;
        sinal_esp32_o    : out std_logic;
        reset_esp32_o    : out std_logic
    );
end entity;

architecture rtl of alarme_controlador is

    type state_t is (
        DESARMADO,
        ARMADO,
        VALIDANDO,
        ATRASO,
        DISPARADO,
        RESET_COMUNICACAO
    );

    signal state            : state_t := DESARMADO;
    signal zones_latched    : std_logic_vector(4 downto 0) := (others => '0');

    signal validation_count : natural range 0 to VALIDATION_SECONDS := 0;
    signal delay_latched    : natural range 0 to 120 := 0;
    signal seconds_count    : natural range 0 to 120 := 0;
    signal watchdog_count   : natural range 0 to WATCHDOG_SECONDS := 0;

    signal ack_received     : std_logic := '0';
    signal any_zone         : std_logic;

    --------------------------------------------------------------------------
    -- Limita o atraso maximo permitido para 120 segundos.
    --------------------------------------------------------------------------
    function clipped_delay(value : unsigned(6 downto 0)) return natural is
        variable converted_value : natural;
    begin
        converted_value := to_integer(value);

        if converted_value > 120 then
            return 120;
        else
            return converted_value;
        end if;
    end function;

begin

    any_zone <= '1' when zones_in /= "00000" else '0';

    zones_latched_o <= zones_latched;

    --------------------------------------------------------------------------
    -- Saidas de estado.
    --------------------------------------------------------------------------
    armado_o <= '0'
        when state = DESARMADO
        else '1';

    disparando_o <= '1'
        when state = DISPARADO or state = RESET_COMUNICACAO
        else '0';

    sirene_o <= '1'
        when state = DISPARADO or state = RESET_COMUNICACAO
        else '0';

    fumaca_o <= '1'
        when state = DISPARADO or state = RESET_COMUNICACAO
        else '0';

    cerca_simulada_o <= '1'
        when state = DISPARADO or state = RESET_COMUNICACAO
        else '0';

    sinal_esp32_o <= '1'
        when state = DISPARADO or state = RESET_COMUNICACAO
        else '0';

    reset_esp32_o <= '1'
        when state = RESET_COMUNICACAO
        else '0';

    --------------------------------------------------------------------------
    -- Codigo do display:
    --   00 = d
    --   01 = A
    --   10 = U
    --------------------------------------------------------------------------
    with state select status_code_o <=
        "00" when DESARMADO,
        "01" when ARMADO,
        "01" when VALIDANDO,
        "01" when ATRASO,
        "10" when DISPARADO,
        "10" when RESET_COMUNICACAO;

    --------------------------------------------------------------------------
    -- Maquina de Estados Finitos.
    --------------------------------------------------------------------------
    process(clk)
        variable selected_delay : natural range 0 to 120;
    begin
        if rising_edge(clk) then

            if rst = '1' then
                state            <= DESARMADO;
                zones_latched    <= (others => '0');
                validation_count <= 0;
                delay_latched    <= 0;
                seconds_count    <= 0;
                watchdog_count   <= 0;
                ack_received     <= '0';

            elsif arm_toggle_pulse = '1' then

                if state = DESARMADO then
                    state <= ARMADO;
                else
                    state <= DESARMADO;
                end if;

                zones_latched    <= (others => '0');
                validation_count <= 0;
                delay_latched    <= 0;
                seconds_count    <= 0;
                watchdog_count   <= 0;
                ack_received     <= '0';

            else

                case state is

                    ------------------------------------------------------------------
                    -- Estado inicial e sistema desativado.
                    ------------------------------------------------------------------
                    when DESARMADO =>
                        zones_latched    <= (others => '0');
                        validation_count <= 0;
                        seconds_count    <= 0;
                        watchdog_count   <= 0;
                        ack_received     <= '0';

                    ------------------------------------------------------------------
                    -- Sistema armado e monitorando as zonas.
                    ------------------------------------------------------------------
                    when ARMADO =>
                        if any_zone = '1' then
                            zones_latched    <= zones_in;
                            validation_count <= 0;
                            state            <= VALIDANDO;
                        end if;

                    ------------------------------------------------------------------
                    -- A zona deve permanecer ativa por pelo menos 1 segundo.
                    ------------------------------------------------------------------
                    when VALIDANDO =>
                        if any_zone = '0' then
                            zones_latched    <= (others => '0');
                            validation_count <= 0;
                            state            <= ARMADO;

                        else
                            zones_latched <= zones_latched or zones_in;

                            if tick_1s = '1' then
                                if validation_count + 1 >= VALIDATION_SECONDS then

                                    selected_delay := clipped_delay(delay_seconds_in);
                                    delay_latched <= selected_delay;
                                    seconds_count <= 0;

                                    if selected_delay = 0 then
                                        state          <= DISPARADO;
                                        watchdog_count <= 0;
                                        ack_received   <= '0';
                                    else
                                        state <= ATRASO;
                                    end if;

                                else
                                    validation_count <= validation_count + 1;
                                end if;
                            end if;
                        end if;

                    ------------------------------------------------------------------
                    -- Conta o tempo selecionado antes de acionar as saidas.
                    ------------------------------------------------------------------
                    when ATRASO =>
                        zones_latched <= zones_latched or zones_in;

                        if tick_1s = '1' then
                            if seconds_count + 1 >= delay_latched then
                                state          <= DISPARADO;
                                seconds_count  <= 0;
                                watchdog_count <= 0;
                                ack_received   <= '0';
                            else
                                seconds_count <= seconds_count + 1;
                            end if;
                        end if;

                    ------------------------------------------------------------------
                    -- Alarme disparado: ativa atuadores e espera ACK do ESP32.
                    ------------------------------------------------------------------
                    when DISPARADO =>
                        zones_latched <= zones_latched or zones_in;

                        if ack_esp32_pulse = '1' then
                            ack_received   <= '1';
                            watchdog_count <= 0;

                        elsif tick_1s = '1' and ack_received = '0' then

                            if watchdog_count + 1 >= WATCHDOG_SECONDS then
                                state          <= RESET_COMUNICACAO;
                                watchdog_count <= 0;
                            else
                                watchdog_count <= watchdog_count + 1;
                            end if;

                        end if;

                    ------------------------------------------------------------------
                    -- Gera comando de reset do ESP32 durante aproximadamente 1 s.
                    ------------------------------------------------------------------
                    when RESET_COMUNICACAO =>
                        zones_latched <= zones_latched or zones_in;

                        if tick_1s = '1' then
                            state          <= DISPARADO;
                            watchdog_count <= 0;
                            ack_received   <= '0';
                        end if;

                end case;
            end if;
        end if;
    end process;

end architecture;