/*
  Projeto: Sistema de Alarme - ESP32 + FPGA Basys 3 via UART

  Arquitetura:
    Sensores -> ESP32 -> UART -> FPGA/Basys 3 -> Atuadores

  Comunicação UART:
    Baud rate: 115200
    Formato: 8N1

  Ligações UART:
    ESP32 GPIO17 TX2 -> FPGA UART_RX / Basys 3 JB1
    ESP32 GPIO16 RX2 <- FPGA UART_TX / Basys 3 JB0
    ESP32 GND        <-> GND Basys 3

  Sensores:
    Zona 1 = Reed switch 1               -> GPIO25
    Zona 2 = Reed switch 2               -> GPIO33
    Zona 3 = PIR + HC-SR04 número 1      -> PIR GPIO13, TRIG GPIO12, ECHO GPIO14
    Zona 4 = Sensor IR obstáculo/linha   -> GPIO27
    Zona 5 = HC-SR04 número 2            -> TRIG GPIO32, ECHO GPIO35

  Pacote ESP32 -> FPGA:
    Byte 0 = START = 0xA5
    Byte 1 = TYPE  = 0x10
    Byte 2 = ZONES
    Byte 3 = FLAGS
    Byte 4 = CHECKSUM

  ZONES:
    bit 0 = Zona 1 violada
    bit 1 = Zona 2 violada
    bit 2 = Zona 3 violada
    bit 3 = Zona 4 violada
    bit 4 = Zona 5 violada

  FLAGS:
    bit 0 = heartbeat / ESP32 vivo
    bit 1 = alerta enviado para nuvem/app com sucesso
    bit 2 = Wi-Fi conectado
*/

#include <Arduino.h>

// =======================================================
// UART FPGA
// =======================================================

constexpr uint8_t UART_RX_FPGA = 16;   // RX2 do ESP32 recebe do TX da FPGA
constexpr uint8_t UART_TX_FPGA = 17;   // TX2 do ESP32 envia para RX da FPGA
constexpr uint32_t UART_BAUD   = 115200;

// =======================================================
// Protocolo UART
// =======================================================

constexpr uint8_t UART_START = 0xA5;

constexpr uint8_t TYPE_ZONES_FROM_ESP32 = 0x10;
constexpr uint8_t TYPE_STATUS_FROM_FPGA = 0x20;
constexpr uint8_t TYPE_REMOTE_COMMAND   = 0x11;

// =======================================================
// Pinagem dos sensores
// =======================================================

constexpr uint8_t PIN_REED_Z1 = 25;
constexpr uint8_t PIN_REED_Z2 = 33;

constexpr uint8_t PIN_PIR_Z3      = 13;
constexpr uint8_t PIN_TRIG_Z3     = 12;
constexpr uint8_t PIN_ECHO_Z3     = 14;

constexpr uint8_t PIN_SENSOR_IR_Z4 =27;

constexpr uint8_t PIN_TRIG_Z5 = 32;
constexpr uint8_t PIN_ECHO_Z5 = 35;

// =======================================================
// LEDs locais opcionais do ESP32
// =======================================================

constexpr uint8_t LED_STATUS = 2;

// =======================================================
// Configurações de leitura
// =======================================================

constexpr unsigned long INTERVALO_ENVIO_UART_MS = 100;
constexpr unsigned long INTERVALO_DEBUG_MS      = 1000;

constexpr float DISTANCIA_LIMITE_Z3_CM = 8.0;
constexpr float DISTANCIA_LIMITE_Z5_CM = 8.0;

constexpr unsigned long TIMEOUT_PULSE_US = 30000;

// Se algum sensor estiver invertido, altere aqui.
constexpr bool REED_Z1_ATIVO_EM_HIGH = true;
constexpr bool REED_Z2_ATIVO_EM_HIGH = true;

// Muitos sensores IR de obstáculo/linha ativam em LOW.
// Se o seu ativar ao contrário, troque para true.
constexpr bool SENSOR_IR_Z4_ATIVO_EM_HIGH = true;

// Zona 3 usa PIR + ultrassônico para reduzir falso positivo.
constexpr bool ZONA3_USA_PIR_E_ULTRASSONICO = true;

// =======================================================
// Estado recebido da FPGA
// =======================================================

struct StatusFpga {
  bool armado = false;
  bool disparando = false;
  bool sireneLigada = false;
  bool estroboLigado = false;
  bool cercaHabilitada = false;
  bool erroComunicacaoEsp32 = false;

  bool zonasLatched[5] = {
    false, false, false, false, false
  };
};

StatusFpga statusFpga;

// =======================================================
// Controle de tempo
// =======================================================

unsigned long ultimoEnvioUart = 0;
unsigned long ultimoDebug = 0;

bool heartbeat = false;
bool alertaEnviadoOk = false;
bool wifiConectado = false;

// =======================================================
// Parser do pacote recebido da FPGA
// =======================================================

enum RxState {
  RX_WAIT_START,
  RX_TYPE,
  RX_DATA0,
  RX_DATA1,
  RX_CHECKSUM
};

RxState rxState = RX_WAIT_START;

uint8_t rxType = 0;
uint8_t rxData0 = 0;
uint8_t rxData1 = 0;

// =======================================================
// Funções auxiliares
// =======================================================

uint8_t calcularChecksum(uint8_t start, uint8_t type, uint8_t data0, uint8_t data1) {
  return start ^ type ^ data0 ^ data1;
}

void enviarPacote(uint8_t type, uint8_t data0, uint8_t data1) {
  uint8_t checksum = calcularChecksum(UART_START, type, data0, data1);

  Serial2.write(UART_START);
  Serial2.write(type);
  Serial2.write(data0);
  Serial2.write(data1);
  Serial2.write(checksum);
}

float medirDistanciaCm(uint8_t trigPin, uint8_t echoPin) {
  digitalWrite(trigPin, LOW);
  delayMicroseconds(2);

  digitalWrite(trigPin, HIGH);
  delayMicroseconds(10);

  digitalWrite(trigPin, LOW);

  unsigned long duracao = pulseIn(echoPin, HIGH, TIMEOUT_PULSE_US);

  if (duracao == 0) {
    return 999.0;
  }

  return duracao / 58.0;
}

bool lerReed(uint8_t pin, bool ativoEmHigh) {
  int leitura = digitalRead(pin);

  if (ativoEmHigh) {
    return leitura == HIGH;
  } else {
    return leitura == LOW;
  }
}

bool lerSensorDigital(uint8_t pin, bool ativoEmHigh) {
  int leitura = digitalRead(pin);

  if (ativoEmHigh) {
    return leitura == HIGH;
  } else {
    return leitura == LOW;
  }
}

// =======================================================
// Leitura das zonas
// =======================================================

bool lerZona1() {
  return lerReed(PIN_REED_Z1, REED_Z1_ATIVO_EM_HIGH);
}

bool lerZona2() {
  return lerReed(PIN_REED_Z2, REED_Z2_ATIVO_EM_HIGH);
}

bool lerZona3() {
  bool pirAtivo = digitalRead(PIN_PIR_Z3) == HIGH;
  float distancia = medirDistanciaCm(PIN_TRIG_Z3, PIN_ECHO_Z3);
  bool ultrassonicoAtivo = distancia <= DISTANCIA_LIMITE_Z3_CM;

  if (ZONA3_USA_PIR_E_ULTRASSONICO) {
    return pirAtivo && ultrassonicoAtivo;
  }

  return pirAtivo || ultrassonicoAtivo;
}

bool lerZona4() {
  return lerSensorDigital(PIN_SENSOR_IR_Z4, SENSOR_IR_Z4_ATIVO_EM_HIGH);
}

bool lerZona5() {
  float distancia = medirDistanciaCm(PIN_TRIG_Z5, PIN_ECHO_Z5);
  return distancia <= DISTANCIA_LIMITE_Z5_CM;
}

uint8_t montarByteZonas() {
  uint8_t zones = 0;

  if (lerZona1()) {
    zones |= (1 << 0);
  }

  if (lerZona2()) {
    zones |= (1 << 1);
  }

  if (lerZona3()) {
    zones |= (1 << 2);
  }

  if (lerZona4()) {
    zones |= (1 << 3);
  }

  if (lerZona5()) {
    zones |= (1 << 4);
  }

  return zones;
}

uint8_t montarByteFlags() {
  uint8_t flags = 0;

  heartbeat = !heartbeat;

  if (heartbeat) {
    flags |= (1 << 0);
  }

  if (alertaEnviadoOk) {
    flags |= (1 << 1);
  }

  if (wifiConectado) {
    flags |= (1 << 2);
  }

  return flags;
}

// =======================================================
// Recebe status da FPGA
// =======================================================

void atualizarStatusFpga(uint8_t status, uint8_t zonesLatched) {
  statusFpga.armado = status & (1 << 0);
  statusFpga.disparando = status & (1 << 1);
  statusFpga.sireneLigada = status & (1 << 2);
  statusFpga.estroboLigado = status & (1 << 3);
  statusFpga.cercaHabilitada = status & (1 << 4);
  statusFpga.erroComunicacaoEsp32 = status & (1 << 5);

  statusFpga.zonasLatched[0] = zonesLatched & (1 << 0);
  statusFpga.zonasLatched[1] = zonesLatched & (1 << 1);
  statusFpga.zonasLatched[2] = zonesLatched & (1 << 2);
  statusFpga.zonasLatched[3] = zonesLatched & (1 << 3);
  statusFpga.zonasLatched[4] = zonesLatched & (1 << 4);

  if (statusFpga.disparando) {
    // Aqui futuramente entra envio para nuvem/app.
    // Por enquanto, consideramos como falso para não enganar a FPGA.
    alertaEnviadoOk = false;
  } else {
    alertaEnviadoOk = false;
  }
}

void processarByteRecebido(uint8_t byteRecebido) {
  switch (rxState) {
    case RX_WAIT_START:
      if (byteRecebido == UART_START) {
        rxState = RX_TYPE;
      }
      break;

    case RX_TYPE:
      rxType = byteRecebido;
      rxState = RX_DATA0;
      break;

    case RX_DATA0:
      rxData0 = byteRecebido;
      rxState = RX_DATA1;
      break;

    case RX_DATA1:
      rxData1 = byteRecebido;
      rxState = RX_CHECKSUM;
      break;

    case RX_CHECKSUM: {
      uint8_t checksumCalculado = calcularChecksum(UART_START, rxType, rxData0, rxData1);

      if (byteRecebido == checksumCalculado) {
        if (rxType == TYPE_STATUS_FROM_FPGA) {
          atualizarStatusFpga(rxData0, rxData1);
        }
      }

      rxState = RX_WAIT_START;
      break;
    }
  }
}

void lerPacotesDaFpga() {
  while (Serial2.available() > 0) {
    uint8_t byteRecebido = Serial2.read();
    processarByteRecebido(byteRecebido);
  }
}

// =======================================================
// Envio para FPGA
// =======================================================

void enviarZonasParaFpga() {
  uint8_t zones = montarByteZonas();
  uint8_t flags = montarByteFlags();

  enviarPacote(TYPE_ZONES_FROM_ESP32, zones, flags);
}

// =======================================================
// Debug
// =======================================================

void imprimirByteBinario(uint8_t valor) {
  for (int i = 7; i >= 0; i--) {
    Serial.print((valor >> i) & 1);
  }
}

void imprimirStatusDebug() {
  uint8_t zones = montarByteZonas();
  uint8_t flags = montarByteFlags();

  Serial.println();
  Serial.println("========== DEBUG ESP32 ALARME UART ==========");

  Serial.print("ZONES atual: 0b");
  imprimirByteBinario(zones);
  Serial.println();

  Serial.print("FLAGS atual: 0b");
  imprimirByteBinario(flags);
  Serial.println();

  Serial.print("Zona 1 Reed: ");
  Serial.println((zones & (1 << 0)) ? "VIOLADA" : "normal");

  Serial.print("Zona 2 Reed: ");
  Serial.println((zones & (1 << 1)) ? "VIOLADA" : "normal");

  Serial.print("Zona 3 PIR + HC-SR04: ");
  Serial.println((zones & (1 << 2)) ? "VIOLADA" : "normal");

  Serial.print("Zona 4 IR: ");
  Serial.println((zones & (1 << 3)) ? "VIOLADA" : "normal");

  Serial.print("Zona 5 HC-SR04: ");
  Serial.println((zones & (1 << 4)) ? "VIOLADA" : "normal");

  Serial.println("---------------------------------------------");

  Serial.print("FPGA armado: ");
  Serial.println(statusFpga.armado ? "SIM" : "NAO");

  Serial.print("FPGA disparando: ");
  Serial.println(statusFpga.disparando ? "SIM" : "NAO");

  Serial.print("Sirene ligada: ");
  Serial.println(statusFpga.sireneLigada ? "SIM" : "NAO");

  Serial.print("Estrobo ligado: ");
  Serial.println(statusFpga.estroboLigado ? "SIM" : "NAO");

  Serial.print("Cerca habilitada: ");
  Serial.println(statusFpga.cercaHabilitada ? "SIM" : "NAO");

  Serial.print("Erro comunicacao ESP32 na FPGA: ");
  Serial.println(statusFpga.erroComunicacaoEsp32 ? "SIM" : "NAO");

  Serial.print("Zonas travadas na FPGA: ");

  bool alguma = false;

  for (int i = 0; i < 5; i++) {
    if (statusFpga.zonasLatched[i]) {
      Serial.print(i + 1);
      Serial.print(" ");
      alguma = true;
    }
  }

  if (!alguma) {
    Serial.print("nenhuma");
  }

  Serial.println();

  Serial.println("=============================================");
}

// =======================================================
// Setup
// =======================================================

void setup() {
  Serial.begin(115200);
  delay(500);

  Serial2.begin(UART_BAUD, SERIAL_8N1, UART_RX_FPGA, UART_TX_FPGA);

  pinMode(PIN_REED_Z1, INPUT_PULLUP);
  pinMode(PIN_REED_Z2, INPUT_PULLUP);

  pinMode(PIN_PIR_Z3, INPUT);

  pinMode(PIN_TRIG_Z3, OUTPUT);
  pinMode(PIN_ECHO_Z3, INPUT);

  pinMode(PIN_SENSOR_IR_Z4, INPUT);

  pinMode(PIN_TRIG_Z5, OUTPUT);
  pinMode(PIN_ECHO_Z5, INPUT);

  pinMode(LED_STATUS, OUTPUT);

  digitalWrite(PIN_TRIG_Z3, LOW);
  digitalWrite(PIN_TRIG_Z5, LOW);
  digitalWrite(LED_STATUS, LOW);

  Serial.println();
  Serial.println("ESP32 iniciado - Sistema de alarme via UART");
  Serial.println("UART Serial2: 115200 8N1");
  Serial.println("TX2 GPIO17 -> FPGA RX");
  Serial.println("RX2 GPIO16 <- FPGA TX");
}

// =======================================================
// Loop principal
// =======================================================

void loop() {
  lerPacotesDaFpga();

  unsigned long agora = millis();

  if (agora - ultimoEnvioUart >= INTERVALO_ENVIO_UART_MS) {
    ultimoEnvioUart = agora;
    enviarZonasParaFpga();

    digitalWrite(LED_STATUS, !digitalRead(LED_STATUS));
  }

  if (agora - ultimoDebug >= INTERVALO_DEBUG_MS) {
    ultimoDebug = agora;
    imprimirStatusDebug();
  }
}