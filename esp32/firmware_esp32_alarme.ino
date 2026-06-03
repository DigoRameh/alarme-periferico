/*
  Projeto: Central de Alarme Perimetrico - ESP32 + Basys 3
  Etapa 2: Leitura FPGA + Sensores locais (PIR + HC-SR04)

  Funcao deste firmware:
    - Ler os sinais de estado enviados pela FPGA pelo Pmod JB;
    - Detectar um novo disparo vindo da FPGA;
    - Ler sensor PIR (zona 3) e confirmar com HC-SR04 (logica AND);
    - Mostrar no Monitor Serial quais zonas foram violadas;
    - Enviar um pulso ACK para a FPGA.
    - Acionar LEDs locais conforme estado do sistema.

  Esta versao NAO usa Wi-Fi nem MQTT.
  Primeiro valide a fiacao e o handshake; depois adicione a nuvem.

  Mapeamento FPGA (Pmod JB) -> ESP32:
    JB(0) -> GPIO 18 : disparo
    JB(1) -> GPIO 19 : armado
    JB(2) -> GPIO 21 : zona 1
    JB(3) -> GPIO 22 : zona 2
    JB(4) -> GPIO 23 : zona 3
    JB(5) -> GPIO 25 : zona 4
    JB(6) -> GPIO 26 : zona 5
    JB(7) <- GPIO 27 : ACK do ESP32 para a FPGA
    GND   <-> GND    : referencia comum obrigatoria

  Sensores locais:
    GPIO 13 : PIR HC-SR501 OUT       (zona 3 — sensor primario)
    GPIO 12 : HC-SR04 TRIG           (sensor de confirmacao)
    GPIO 14 : HC-SR04 ECHO           (divisor 1kOhm + 2kOhm obrigatorio!)
    GPIO  2 : LED verde              (sistema armado)
    GPIO  4 : LED amarelo            (PIR detectou movimento)
    GPIO 15 : LED azul               (alarme confirmado PIR + HC-SR04)
    GPIO 32 : Botao                  (armar / desarmar local)
*/

#include <Arduino.h>

// -------------------------------------------------------
// Pinos FPGA (Pmod JB)
// -------------------------------------------------------
constexpr uint8_t PIN_DISPARO = 18;
constexpr uint8_t PIN_ARMADO  = 19;
constexpr uint8_t PIN_ZONA_1  = 21;
constexpr uint8_t PIN_ZONA_2  = 22;
constexpr uint8_t PIN_ZONA_3  = 23;
constexpr uint8_t PIN_ZONA_4  = 25;
constexpr uint8_t PIN_ZONA_5  = 26;
constexpr uint8_t PIN_ACK     = 27;

// -------------------------------------------------------
// Sensores locais
// -------------------------------------------------------
constexpr uint8_t PIN_PIR     = 13;
constexpr uint8_t PIN_TRIG    = 12;
constexpr uint8_t PIN_ECHO    = 14;

// -------------------------------------------------------
// LEDs e botao
// -------------------------------------------------------
constexpr uint8_t LED_VERDE   = 2;
constexpr uint8_t LED_AMARELO = 4;
constexpr uint8_t LED_AZUL    = 15;
constexpr uint8_t PIN_BOTAO   = 32;

// -------------------------------------------------------
// Configuracoes
// -------------------------------------------------------
constexpr unsigned long DURACAO_ACK_MS      = 100;
constexpr unsigned long INTERVALO_STATUS_MS = 1000;
constexpr float         DISTANCIA_LIMITE_CM = 5.0; // HC-SR04: abaixo disso confirma o PIR
constexpr unsigned long DEBOUNCE_PIR_MS     = 300;   // ignora pulsos PIR menores que 300ms
constexpr unsigned long DEBOUNCE_BOTAO_MS   = 50;

// -------------------------------------------------------
// Variaveis de estado
// -------------------------------------------------------
struct EstadoAlarme {
  bool disparo;
  bool armado;
  bool zonas[5];
};

bool disparoAnterior      = false;
bool armadoAnterior       = false;
bool alarmeLocalAtivo     = false;

unsigned long instanteUltimoStatus = 0;
unsigned long ultimoTempoPIR       = 0;
unsigned long ultimoTempoBotao     = 0;
int           ultimoBotao          = HIGH;

// -------------------------------------------------------
// Mede distancia em cm via HC-SR04
// -------------------------------------------------------
float medirDistancia() {
  digitalWrite(PIN_TRIG, LOW);
  delayMicroseconds(2);
  digitalWrite(PIN_TRIG, HIGH);
  delayMicroseconds(10);
  digitalWrite(PIN_TRIG, LOW);

  long duracao = pulseIn(PIN_ECHO, HIGH, 30000); // timeout 30ms ~ 5m
  if (duracao == 0) return 999.0;                // sem retorno = objeto ausente

  return duracao / 58.0;
}

// -------------------------------------------------------
// Le todos os sinais enviados pela FPGA
// -------------------------------------------------------
EstadoAlarme lerEstadoDaFpga() {
  EstadoAlarme estado{};

  estado.disparo   = digitalRead(PIN_DISPARO) == HIGH;
  estado.armado    = digitalRead(PIN_ARMADO)  == HIGH;
  estado.zonas[0]  = digitalRead(PIN_ZONA_1)  == HIGH;
  estado.zonas[1]  = digitalRead(PIN_ZONA_2)  == HIGH;
  estado.zonas[2]  = digitalRead(PIN_ZONA_3)  == HIGH;
  estado.zonas[3]  = digitalRead(PIN_ZONA_4)  == HIGH;
  estado.zonas[4]  = digitalRead(PIN_ZONA_5)  == HIGH;

  return estado;
}

// -------------------------------------------------------
// Imprime zonas violadas
// -------------------------------------------------------
void imprimirZonasVioladas(const EstadoAlarme &estado) {
  bool encontrouZona = false;

  Serial.print("Zonas violadas: ");

  for (uint8_t i = 0; i < 5; i++) {
    if (estado.zonas[i]) {
      if (encontrouZona) Serial.print(", ");
      Serial.print(i + 1);
      encontrouZona = true;
    }
  }

  if (!encontrouZona) Serial.print("nenhuma identificada");

  Serial.println();
}

// -------------------------------------------------------
// Envia ACK para a FPGA
// -------------------------------------------------------
void enviarAckParaFpga() {
  Serial.println("Enviando ACK para a FPGA...");
  digitalWrite(PIN_ACK, HIGH);
  delay(DURACAO_ACK_MS);
  digitalWrite(PIN_ACK, LOW);
  Serial.println("ACK enviado.");
}

// -------------------------------------------------------
// Trata novo disparo vindo da FPGA
// -------------------------------------------------------
void tratarNovoDisparo(const EstadoAlarme &estado) {
  Serial.println();
  Serial.println("========================================");
  Serial.println("NOVO EVENTO DE ALARME RECEBIDO DA FPGA");
  Serial.println("Status: DISPARADO");

  imprimirZonasVioladas(estado);

  Serial.println("Contramedidas controladas pela FPGA: habilitadas");

  // acende LEDs de alarme
  digitalWrite(LED_AMARELO, HIGH);
  digitalWrite(LED_AZUL,    HIGH);

  enviarAckParaFpga();

  Serial.println("========================================");
  Serial.println();
}

// -------------------------------------------------------
// Trata leitura dos sensores locais (PIR + HC-SR04)
// Zona 3 — logica AND para reducao de falso positivo
// -------------------------------------------------------
void tratarSensoresLocais(const EstadoAlarme &estadoFpga) {

  // so monitora sensores locais se o sistema estiver armado
  if (!estadoFpga.armado) {
    digitalWrite(LED_AMARELO, LOW);
    if (!alarmeLocalAtivo) digitalWrite(LED_AZUL, LOW);
    return;
  }

  int pirLeitura = digitalRead(PIN_PIR);

  if (pirLeitura == HIGH) {
    unsigned long agora = millis();

    // debounce — ignora pulsos curtos (falso positivo termico)
    if ((agora - ultimoTempoPIR) < DEBOUNCE_PIR_MS) return;
    ultimoTempoPIR = agora;

    Serial.println("[PIR] Movimento detectado na Zona 3 — aguardando confirmacao HC-SR04...");
    digitalWrite(LED_AMARELO, HIGH);

    // confirmacao pelo HC-SR04
    float distancia = medirDistancia();
    Serial.print("[HC-SR04] Distancia medida: ");
    Serial.print(distancia);
    Serial.println(" cm");

    if (distancia < DISTANCIA_LIMITE_CM) {
      // CONFIRMADO — ambos os sensores concordam
      alarmeLocalAtivo = true;
      digitalWrite(LED_AZUL, HIGH);

      Serial.println();
      Serial.println("========================================");
      Serial.println("ALARME LOCAL — ZONA 3");
      Serial.println("Confirmado por PIR + HC-SR04");
      Serial.print("Distancia do intruso: ");
      Serial.print(distancia);
      Serial.println(" cm");
      Serial.println("Aguardando confirmacao da FPGA via PIN_DISPARO...");
      Serial.println("========================================");
      Serial.println();

      // pisca LED azul 5x
      for (int i = 0; i < 5; i++) {
        digitalWrite(LED_AZUL, LOW);
        delay(100);
        digitalWrite(LED_AZUL, HIGH);
        delay(100);
      }

    } else {
      // PIR disparou mas HC-SR04 nao confirmou — falso positivo
      Serial.println("[INFO] Falso positivo ignorado — HC-SR04 sem objeto proximo");
      digitalWrite(LED_AMARELO, LOW);
    }

  } else {
    // sem movimento — apaga amarelo se alarme local nao ativo
    if (!alarmeLocalAtivo) {
      digitalWrite(LED_AMARELO, LOW);
    }
  }
}

// -------------------------------------------------------
// Le botao com debounce — alterna armado/desarmado local
// (util para teste sem FPGA conectada)
// -------------------------------------------------------
void lerBotao() {
  int leitura = digitalRead(PIN_BOTAO);

  if (leitura != ultimoBotao) ultimoTempoBotao = millis();

  if ((millis() - ultimoTempoBotao) > DEBOUNCE_BOTAO_MS) {
    if (leitura == LOW) {
      alarmeLocalAtivo = false;
      digitalWrite(LED_AMARELO, LOW);
      digitalWrite(LED_AZUL,    LOW);
      Serial.println("[BOTAO] Alarme local resetado.");
      delay(500);
    }
  }

  ultimoBotao = leitura;
}

// -------------------------------------------------------
// Status periodico no Monitor Serial
// -------------------------------------------------------
void imprimirStatusPeriodico(const EstadoAlarme &estado) {
  Serial.print("Status FPGA: ");

  if (estado.disparo)     Serial.print("DISPARADO");
  else if (estado.armado) Serial.print("ARMADO");
  else                    Serial.print("DESARMADO");

  Serial.print(" | PIR local: ");
  Serial.print(digitalRead(PIN_PIR) ? "ATIVO" : "inativo");

  if (estado.armado || estado.disparo) {
    Serial.print(" | ");
    imprimirZonasVioladas(estado);
  } else {
    Serial.println();
  }
}

// -------------------------------------------------------
// SETUP
// -------------------------------------------------------
void setup() {
  Serial.begin(115200);
  delay(500);

  // entradas FPGA
  pinMode(PIN_DISPARO, INPUT_PULLDOWN);
  pinMode(PIN_ARMADO,  INPUT_PULLDOWN);
  pinMode(PIN_ZONA_1,  INPUT_PULLDOWN);
  pinMode(PIN_ZONA_2,  INPUT_PULLDOWN);
  pinMode(PIN_ZONA_3,  INPUT_PULLDOWN);
  pinMode(PIN_ZONA_4,  INPUT_PULLDOWN);
  pinMode(PIN_ZONA_5,  INPUT_PULLDOWN);

  // saida ACK
  pinMode(PIN_ACK, OUTPUT);
  digitalWrite(PIN_ACK, LOW);

  // sensores locais
  pinMode(PIN_PIR,  INPUT);
  pinMode(PIN_ECHO, INPUT);
  pinMode(PIN_TRIG, OUTPUT);
  digitalWrite(PIN_TRIG, LOW);

  // LEDs e botao
  pinMode(LED_VERDE,   OUTPUT);
  pinMode(LED_AMARELO, OUTPUT);
  pinMode(LED_AZUL,    OUTPUT);
  pinMode(PIN_BOTAO,   INPUT_PULLUP);

  digitalWrite(LED_VERDE,   LOW);
  digitalWrite(LED_AMARELO, LOW);
  digitalWrite(LED_AZUL,    LOW);

  EstadoAlarme estadoInicial = lerEstadoDaFpga();
  disparoAnterior = false;
  armadoAnterior  = estadoInicial.armado;

  Serial.println();
  Serial.println("ESP32 iniciado - Etapa 2: FPGA + PIR + HC-SR04");
  Serial.println("Monitor Serial: 115200 baud");
  Serial.println("Aguardando sinais da Basys 3...");
  imprimirStatusPeriodico(estadoInicial);
}

// -------------------------------------------------------
// LOOP
// -------------------------------------------------------
void loop() {
  EstadoAlarme estado = lerEstadoDaFpga();

  // LED verde indica sistema armado
  digitalWrite(LED_VERDE, estado.armado ? HIGH : LOW);

  // detecta mudanca armado/desarmado
  if (estado.armado != armadoAnterior && !estado.disparo) {
    Serial.println(estado.armado
      ? "Sistema foi ARMADO pela FPGA."
      : "Sistema foi DESARMADO pela FPGA.");
    armadoAnterior = estado.armado;

    // ao desarmar, apaga alarme local
    if (!estado.armado) {
      alarmeLocalAtivo = false;
      digitalWrite(LED_AMARELO, LOW);
      digitalWrite(LED_AZUL,    LOW);
    }
  }

  // detecta subida do sinal de disparo vindo da FPGA
  if (estado.disparo && !disparoAnterior) {
    tratarNovoDisparo(estado);
  }
  disparoAnterior = estado.disparo;

  // sensores locais PIR + HC-SR04
  tratarSensoresLocais(estado);

  // botao local de reset
  lerBotao();

  // status periodico
  const unsigned long agora = millis();
  if (agora - instanteUltimoStatus >= INTERVALO_STATUS_MS) {
    instanteUltimoStatus = agora;
    imprimirStatusPeriodico(estado);
  }

  delay(10);
}
