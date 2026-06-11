/*
  Projeto: Sistema de Alarme - ESP32 + FPGA Basys 3 via UART

  Arquitetura:
    Sensores -> ESP32 -> UART -> FPGA/Basys 3 -> Atuadores

  UART:
    Baud rate: 115200
    Formato: 8N1

  Ligações UART:
    ESP32 GPIO17 TX2 -> FPGA UART_RX / Basys 3 JB2
    ESP32 GPIO16 RX2 <- FPGA UART_TX / Basys 3 JB1
    ESP32 GND        <-> GND Basys 3

  Sensores:
    Zona 1: Reed switch 1               -> GPIO25
    Zona 2: Reed switch 2               -> GPIO33
    Zona 3: PIR + HC-SR04 número 1      -> PIR 13, TRIG 12, ECHO 14
    Zona 4: Sensor IR                   -> GPIO27
    Zona 5: HC-SR04 número 2            -> TRIG 32, ECHO 35

  Pacote ESP32 -> FPGA:
    0xA5 | 0x10 | ZONES | FLAGS | CHECKSUM

  Pacote FPGA -> ESP32:
    0xA5 | 0x20 | STATUS | ZONES_LATCHED | CHECKSUM
*/

#include <Arduino.h>

// =======================================================
// UART
// =======================================================

constexpr uint8_t UART_RX_FPGA = 16;
constexpr uint8_t UART_TX_FPGA = 17;
constexpr uint32_t UART_BAUD = 115200;

// =======================================================
// Protocolo UART
// =======================================================

constexpr uint8_t UART_START = 0xA5;
constexpr uint8_t TYPE_ZONES_FROM_ESP32 = 0x10;
constexpr uint8_t TYPE_STATUS_FROM_FPGA = 0x20;

// =======================================================
// Pinos
// =======================================================

constexpr uint8_t PIN_REED_Z1 = 25;
constexpr uint8_t PIN_REED_Z2 = 33;

constexpr uint8_t PIN_PIR_Z3 = 13;
constexpr uint8_t PIN_TRIG_Z3 = 12;
constexpr uint8_t PIN_ECHO_Z3 = 14;

constexpr uint8_t PIN_SENSOR_IR_Z4 = 27;

constexpr uint8_t PIN_TRIG_Z5 = 32;
constexpr uint8_t PIN_ECHO_Z5 = 35;

constexpr uint8_t LED_STATUS = 2;

// =======================================================
// Habilitação das zonas
// =======================================================

// Reeds desativados por enquanto.
// Troque para true quando quiser utilizá-los.
constexpr bool HABILITAR_ZONA_1 = false;
constexpr bool HABILITAR_ZONA_2 = false;

constexpr bool HABILITAR_ZONA_3 = true;
constexpr bool HABILITAR_ZONA_4 = true;
constexpr bool HABILITAR_ZONA_5 = true;

// =======================================================
// Configurações
// =======================================================

constexpr unsigned long INTERVALO_SENSORES_MS = 100;
constexpr unsigned long INTERVALO_ENVIO_UART_MS = 100;
constexpr unsigned long INTERVALO_DEBUG_MS = 1000;

constexpr unsigned long FILTRO_REED_MS = 80;
constexpr unsigned long FILTRO_IR_Z4_MS = 200;

constexpr unsigned long TIMEOUT_ULTRASSONICO_US = 12000;

constexpr float DISTANCIA_LIMITE_Z3_CM = 8.0;
constexpr float DISTANCIA_LIMITE_Z5_CM = 8.0;

// Reed ligado entre GPIO e GND com INPUT_PULLUP:
// fechado = LOW
// aberto = HIGH, considerado violado.
constexpr bool REED_ATIVO_EM_HIGH = true;

// Sensor IR normalmente:
// sem objeto = HIGH
// com objeto = LOW
constexpr bool SENSOR_IR_ATIVO_EM_HIGH = false;

// true: Zona 3 exige PIR E ultrassônico.
// false: Zona 3 dispara com PIR OU ultrassônico.
constexpr bool ZONA3_EXIGE_PIR_E_ULTRASSONICO = true;

// =======================================================
// Estruturas
// =======================================================

struct StatusFpga {
  bool armado = false;
  bool disparando = false;
  bool sireneLigada = false;
  bool estroboLigado = false;
  bool cercaHabilitada = false;
  bool erroComunicacaoEsp32 = false;
  bool zonasLatched[5] = {false, false, false, false, false};
};

struct EstadoSensores {
  bool zona1 = false;
  bool zona2 = false;
  bool zona3 = false;
  bool zona4 = false;
  bool zona5 = false;

  bool pirZ3 = false;
  bool irZ4Bruto = false;

  float distanciaZ3 = 999.0;
  float distanciaZ5 = 999.0;
};

StatusFpga statusFpga;
EstadoSensores sensores;

// =======================================================
// Estado global
// =======================================================

unsigned long ultimoCicloSensores = 0;
unsigned long ultimoEnvioUart = 0;
unsigned long ultimoDebug = 0;

uint8_t zonasAtuais = 0;
uint8_t flagsAtuais = 0;

bool heartbeat = false;
bool alertaEnviadoOk = false;
bool wifiConectado = false;

// =======================================================
// Parser UART
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
// Filtro digital reutilizável
// =======================================================

struct FiltroDigital {
  bool leituraAnterior = false;
  bool estadoFiltrado = false;
  unsigned long instanteMudanca = 0;
};

FiltroDigital filtroReedZ1;
FiltroDigital filtroReedZ2;
FiltroDigital filtroIrZ4;

bool atualizarFiltro(
  FiltroDigital &filtro,
  bool leituraAtual,
  unsigned long tempoFiltroMs
) {
  unsigned long agora = millis();

  if (leituraAtual != filtro.leituraAnterior) {
    filtro.leituraAnterior = leituraAtual;
    filtro.instanteMudanca = agora;
  }

  if (agora - filtro.instanteMudanca >= tempoFiltroMs) {
    filtro.estadoFiltrado = leituraAtual;
  }

  return filtro.estadoFiltrado;
}

// =======================================================
// UART
// =======================================================

uint8_t calcularChecksum(
  uint8_t start,
  uint8_t type,
  uint8_t data0,
  uint8_t data1
) {
  return start ^ type ^ data0 ^ data1;
}

void enviarPacote(
  uint8_t type,
  uint8_t data0,
  uint8_t data1
) {
  const uint8_t checksum =
    calcularChecksum(UART_START, type, data0, data1);

  Serial2.write(UART_START);
  Serial2.write(type);
  Serial2.write(data0);
  Serial2.write(data1);
  Serial2.write(checksum);
}

void atualizarStatusFpga(
  uint8_t status,
  uint8_t zonasLatched
) {
  statusFpga.armado =
    (status & (1 << 0)) != 0;

  statusFpga.disparando =
    (status & (1 << 1)) != 0;

  statusFpga.sireneLigada =
    (status & (1 << 2)) != 0;

  statusFpga.estroboLigado =
    (status & (1 << 3)) != 0;

  statusFpga.cercaHabilitada =
    (status & (1 << 4)) != 0;

  statusFpga.erroComunicacaoEsp32 =
    (status & (1 << 5)) != 0;

  for (uint8_t i = 0; i < 5; i++) {
    statusFpga.zonasLatched[i] =
      (zonasLatched & (1 << i)) != 0;
  }

  /*
    Quando houver integração real com nuvem/app,
    altere alertaEnviadoOk para true somente após
    confirmação do envio.
  */
  alertaEnviadoOk = false;
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
      const uint8_t checksumEsperado =
        calcularChecksum(
          UART_START,
          rxType,
          rxData0,
          rxData1
        );

      if (
        byteRecebido == checksumEsperado &&
        rxType == TYPE_STATUS_FROM_FPGA
      ) {
        atualizarStatusFpga(rxData0, rxData1);
      }

      rxState = RX_WAIT_START;
      break;
    }
  }
}

void lerPacotesDaFpga() {
  while (Serial2.available() > 0) {
    const int valor = Serial2.read();

    if (valor >= 0) {
      processarByteRecebido(
        static_cast<uint8_t>(valor)
      );
    }
  }
}

// =======================================================
// Sensores
// =======================================================

float medirDistanciaCm(
  uint8_t trigPin,
  uint8_t echoPin
) {
  digitalWrite(trigPin, LOW);
  delayMicroseconds(2);

  digitalWrite(trigPin, HIGH);
  delayMicroseconds(10);

  digitalWrite(trigPin, LOW);

  const unsigned long duracao = pulseIn(
    echoPin,
    HIGH,
    TIMEOUT_ULTRASSONICO_US
  );

  if (duracao == 0) {
    return 999.0;
  }

  return duracao / 58.0;
}

bool interpretarNivelDigital(
  uint8_t pin,
  bool ativoEmHigh
) {
  const bool nivelHigh = digitalRead(pin) == HIGH;

  return ativoEmHigh
    ? nivelHigh
    : !nivelHigh;
}

bool lerZona1() {
  if (!HABILITAR_ZONA_1) {
    return false;
  }

  const bool leitura = interpretarNivelDigital(
    PIN_REED_Z1,
    REED_ATIVO_EM_HIGH
  );

  return atualizarFiltro(
    filtroReedZ1,
    leitura,
    FILTRO_REED_MS
  );
}

bool lerZona2() {
  if (!HABILITAR_ZONA_2) {
    return false;
  }

  const bool leitura = interpretarNivelDigital(
    PIN_REED_Z2,
    REED_ATIVO_EM_HIGH
  );

  return atualizarFiltro(
    filtroReedZ2,
    leitura,
    FILTRO_REED_MS
  );
}

bool lerZona3() {
  if (!HABILITAR_ZONA_3) {
    sensores.pirZ3 = false;
    sensores.distanciaZ3 = 999.0;
    return false;
  }

  sensores.pirZ3 =
    digitalRead(PIN_PIR_Z3) == HIGH;

  sensores.distanciaZ3 =
    medirDistanciaCm(PIN_TRIG_Z3, PIN_ECHO_Z3);

  const bool ultrassonicoAtivo =
    sensores.distanciaZ3 <= DISTANCIA_LIMITE_Z3_CM;

  if (ZONA3_EXIGE_PIR_E_ULTRASSONICO) {
    return sensores.pirZ3 && ultrassonicoAtivo;
  }

  return sensores.pirZ3 || ultrassonicoAtivo;
}

bool lerZona4() {
  if (!HABILITAR_ZONA_4) {
    sensores.irZ4Bruto = false;
    return false;
  }

  const bool nivelHigh =
    digitalRead(PIN_SENSOR_IR_Z4) == HIGH;

  sensores.irZ4Bruto = nivelHigh;

  const bool leituraInterpretada =
    SENSOR_IR_ATIVO_EM_HIGH
      ? nivelHigh
      : !nivelHigh;

  return atualizarFiltro(
    filtroIrZ4,
    leituraInterpretada,
    FILTRO_IR_Z4_MS
  );
}

bool lerZona5() {
  if (!HABILITAR_ZONA_5) {
    sensores.distanciaZ5 = 999.0;
    return false;
  }

  sensores.distanciaZ5 =
    medirDistanciaCm(PIN_TRIG_Z5, PIN_ECHO_Z5);

  return sensores.distanciaZ5 <=
         DISTANCIA_LIMITE_Z5_CM;
}

void atualizarSensores() {
  sensores.zona1 = lerZona1();
  sensores.zona2 = lerZona2();
  sensores.zona3 = lerZona3();

  /*
    Pequeno intervalo entre os dois HC-SR04 para reduzir
    interferência acústica entre os sensores.
  */
  delay(5);

  sensores.zona4 = lerZona4();
  sensores.zona5 = lerZona5();

  zonasAtuais = 0;

  if (sensores.zona1) {
    zonasAtuais |= (1 << 0);
  }

  if (sensores.zona2) {
    zonasAtuais |= (1 << 1);
  }

  if (sensores.zona3) {
    zonasAtuais |= (1 << 2);
  }

  if (sensores.zona4) {
    zonasAtuais |= (1 << 3);
  }

  if (sensores.zona5) {
    zonasAtuais |= (1 << 4);
  }
}

// =======================================================
// Flags e envio UART
// =======================================================

uint8_t montarFlags() {
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

void enviarZonasParaFpga() {
  flagsAtuais = montarFlags();

  enviarPacote(
    TYPE_ZONES_FROM_ESP32,
    zonasAtuais,
    flagsAtuais
  );
}

// =======================================================
// Debug
// =======================================================

void imprimirByteBinario(uint8_t valor) {
  for (int i = 7; i >= 0; i--) {
    Serial.print((valor >> i) & 1);
  }
}

void imprimirDistancia(float distancia) {
  if (distancia >= 999.0) {
    Serial.print("sem resposta");
  } else {
    Serial.print(distancia, 1);
    Serial.print(" cm");
  }
}

void imprimirStatusDebug() {
  Serial.println();
  Serial.println(
    "========== DEBUG ESP32 ALARME UART =========="
  );

  Serial.print("ZONES: 0b");
  imprimirByteBinario(zonasAtuais);
  Serial.println();

  Serial.print("FLAGS: 0b");
  imprimirByteBinario(flagsAtuais);
  Serial.println();

  Serial.println("---------------------------------------------");

  Serial.print("Zona 1 Reed: ");
  if (!HABILITAR_ZONA_1) {
    Serial.println("DESATIVADA");
  } else {
    Serial.println(
      sensores.zona1 ? "VIOLADA" : "normal"
    );
  }

  Serial.print("Zona 2 Reed: ");
  if (!HABILITAR_ZONA_2) {
    Serial.println("DESATIVADA");
  } else {
    Serial.println(
      sensores.zona2 ? "VIOLADA" : "normal"
    );
  }

  Serial.print("PIR Zona 3: ");
  Serial.println(
    sensores.pirZ3 ? "ATIVO" : "inativo"
  );

  Serial.print("Distancia Zona 3: ");
  imprimirDistancia(sensores.distanciaZ3);
  Serial.println();

  Serial.print("Zona 3 PIR + HC-SR04: ");
  Serial.println(
    sensores.zona3 ? "VIOLADA" : "normal"
  );

  Serial.print("GPIO27 bruto Zona 4: ");
  Serial.println(
    sensores.irZ4Bruto ? "HIGH" : "LOW"
  );

  Serial.print("Zona 4 IR filtrada: ");
  Serial.println(
    sensores.zona4 ? "VIOLADA" : "normal"
  );

  Serial.print("Distancia Zona 5: ");
  imprimirDistancia(sensores.distanciaZ5);
  Serial.println();

  Serial.print("Zona 5 HC-SR04: ");
  Serial.println(
    sensores.zona5 ? "VIOLADA" : "normal"
  );

  Serial.println("---------------------------------------------");

  Serial.print("FPGA armado: ");
  Serial.println(
    statusFpga.armado ? "SIM" : "NAO"
  );

  Serial.print("FPGA disparando: ");
  Serial.println(
    statusFpga.disparando ? "SIM" : "NAO"
  );

  Serial.print("Sirene ligada: ");
  Serial.println(
    statusFpga.sireneLigada ? "SIM" : "NAO"
  );

  Serial.print("Estrobo ligado: ");
  Serial.println(
    statusFpga.estroboLigado ? "SIM" : "NAO"
  );

  Serial.print("Cerca habilitada: ");
  Serial.println(
    statusFpga.cercaHabilitada ? "SIM" : "NAO"
  );

  Serial.print("Erro comunicacao ESP32 na FPGA: ");
  Serial.println(
    statusFpga.erroComunicacaoEsp32
      ? "SIM"
      : "NAO"
  );

  Serial.print("Zonas travadas na FPGA: ");

  bool algumaZona = false;

  for (uint8_t i = 0; i < 5; i++) {
    if (statusFpga.zonasLatched[i]) {
      Serial.print(i + 1);
      Serial.print(" ");
      algumaZona = true;
    }
  }

  if (!algumaZona) {
    Serial.print("nenhuma");
  }

  Serial.println();
  Serial.println(
    "============================================="
  );
}

// =======================================================
// Setup
// =======================================================

void setup() {
  Serial.begin(115200);
  delay(500);

  Serial2.begin(
    UART_BAUD,
    SERIAL_8N1,
    UART_RX_FPGA,
    UART_TX_FPGA
  );

  pinMode(PIN_REED_Z1, INPUT_PULLUP);
  pinMode(PIN_REED_Z2, INPUT_PULLUP);

  pinMode(PIN_PIR_Z3, INPUT);

  pinMode(PIN_TRIG_Z3, OUTPUT);
  pinMode(PIN_ECHO_Z3, INPUT);

  pinMode(PIN_SENSOR_IR_Z4, INPUT_PULLUP);

  pinMode(PIN_TRIG_Z5, OUTPUT);
  pinMode(PIN_ECHO_Z5, INPUT);

  pinMode(LED_STATUS, OUTPUT);

  digitalWrite(PIN_TRIG_Z3, LOW);
  digitalWrite(PIN_TRIG_Z5, LOW);
  digitalWrite(LED_STATUS, LOW);

  Serial.println();
  Serial.println(
    "ESP32 iniciado - Sistema de alarme UART"
  );
  Serial.println("UART: 115200 8N1");
  Serial.println("GPIO17 TX2 -> FPGA RX / JB2");
  Serial.println("GPIO16 RX2 <- FPGA TX / JB1");
  Serial.println("Sensor IR Zona 4 -> GPIO27");
}

// =======================================================
// Loop
// =======================================================

void loop() {
  lerPacotesDaFpga();

  const unsigned long agora = millis();

  if (
    agora - ultimoCicloSensores >= INTERVALO_SENSORES_MS
  ) {
    ultimoCicloSensores = agora;
    atualizarSensores();
  }

  if (
    agora - ultimoEnvioUart >= INTERVALO_ENVIO_UART_MS
  ) {
    ultimoEnvioUart = agora;

    enviarZonasParaFpga();

    digitalWrite(
      LED_STATUS,
      !digitalRead(LED_STATUS)
    );
  }

  if (
    agora - ultimoDebug >= INTERVALO_DEBUG_MS
  ) {
    ultimoDebug = agora;
    imprimirStatusDebug();
  }
}
