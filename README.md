# Sistema de Alarme Perimétrico com FPGA Basys 3 e ESP32

Projeto final de **Sistemas Embarcados**: central de alarme controlada por FPGA Basys 3, comunicação com ESP32, detecção de zonas, contramedidas e futura integração IoT com MQTT e dashboard.

## Objetivo

Desenvolver um protótipo em maquete capaz de monitorar zonas, identificar violações, temporizar o disparo, acionar contramedidas de forma controlada e comunicar o evento ao usuário.

> **Segurança do protótipo:** as saídas da FPGA e do ESP32 são sinais lógicos de baixa tensão. Atuadores externos devem utilizar interfaces/driver adequados. Não conectar cargas diretamente às placas.

## Estado atual

| Módulo | Status |
|---|---:|
| Central FPGA / MEF em VHDL | ✅ Desenvolvida |
| Indicação `d`, `A`, `U` e LEDs | ✅ Desenvolvida |
| Ligação Basys 3 ↔ ESP32 | ✅ Problema de armado/Zona 2 corrigido |
| Firmware ESP32 com leitura e ACK | 🟡 Validar ACK e watchdog |
| Circuito da cerca/contramedida | 🟡 Montado; falta validar acionamento pela FPGA |
| Gerador de névoa/fumaça segura | ⬜ Pendente |
| Sensores físicos das cinco zonas | ⬜ Pendente |
| MQTT, dashboard, alertas e banco | ⬜ Pendente |

## Arquitetura

```text
Sensores / zonas --> FPGA Basys 3 --> Pmod JB --> ESP32 --> MQTT --> Dashboard / alertas / banco
                         |
                         +--> comandos lógicos de atuadores por Pmod JA
```

## Ligações FPGA ↔ ESP32

| Basys 3 | ESP32 | Função |
|---|---:|---|
| `JB1 / JB(0)` | GPIO 18 | Disparo |
| `JB2 / JB(1)` | GPIO 19 | Sistema armado |
| `JB3 / JB(2)` | GPIO 21 | Zona 1 |
| `JB4 / JB(3)` | GPIO 22 | Zona 2 |
| `JB7 / JB(4)` | GPIO 23 | Zona 3 |
| `JB8 / JB(5)` | GPIO 25 | Zona 4 |
| `JB9 / JB(6)` | GPIO 26 | Zona 5 |
| `JB10 / JB(7)` | GPIO 27 | ACK ESP32 → FPGA |
| `GND` | `GND` | Referência elétrica comum |

## Organização do repositório

```text
alarme-periferico/
├── README.md
├── .gitignore
├── fpga/
│   ├── src/
│   ├── constraints/
│   └── sim/
├── esp32/
├── hardware/
├── docs/
└── video/
```

## Próximas prioridades

1. Validar as cinco zonas, ACK e watchdog.
2. Integrar a contramedida já montada ao comando lógico da FPGA com interface segura.
3. Montar o gerador de névoa/fumaça segura.
4. Integrar sensores físicos.
5. Implementar Wi-Fi e MQTT no ESP32.
6. Criar dashboard, alertas e histórico em banco.
7. Finalizar maquete, documentação, vídeo e pitch.

## Documentação

- [`docs/CHECKLIST.md`](docs/CHECKLIST.md): status e plano de execução.
- [`hardware/LIGACOES_FPGA_ESP32.md`](hardware/LIGACOES_FPGA_ESP32.md): montagem da comunicação.
- [`esp32/firmware_esp32_alarme.ino`](esp32/firmware_esp32_alarme.ino): firmware atual.

## Tecnologias

`VHDL` · `Vivado` · `Basys 3` · `Artix-7` · `ESP32` · `Arduino IDE` · `MQTT` · `IoT` · `Sistemas Embarcados`
