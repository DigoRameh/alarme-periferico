# Ligações FPGA Basys 3 ↔ ESP32

## Comunicação pelo Pmod JB

| Basys 3 | ESP32 | Direção | Função |
|---|---:|---|---|
| `JB1 / JB(0)` | GPIO 18 | FPGA → ESP32 | Disparo |
| `JB2 / JB(1)` | GPIO 19 | FPGA → ESP32 | Armado |
| `JB3 / JB(2)` | GPIO 21 | FPGA → ESP32 | Zona 1 |
| `JB4 / JB(3)` | GPIO 22 | FPGA → ESP32 | Zona 2 |
| `JB7 / JB(4)` | GPIO 23 | FPGA → ESP32 | Zona 3 |
| `JB8 / JB(5)` | GPIO 25 | FPGA → ESP32 | Zona 4 |
| `JB9 / JB(6)` | GPIO 26 | FPGA → ESP32 | Zona 5 |
| `JB10 / JB(7)` | GPIO 27 | ESP32 → FPGA | ACK |
| `GND` | `GND` | — | Terra comum |

## Posição física do Pmod JB

```text
Fileira superior:  JB1    JB2    JB3    JB4    GND    3V3
Fileira inferior:  JB7    JB8    JB9    JB10   GND    3V3
```

## Cuidados

- Alimente Basys 3 e ESP32 pelos próprios cabos USB.
- Conecte o GND comum.
- Não conecte `3V3/VCC` entre as placas neste teste.
- Não conecte atuadores diretamente aos pinos Pmod.
- Faça alterações na fiação com as placas desligadas.

## Saídas previstas para atuadores pelo Pmod JA

| Saída | Função |
|---|---|
| `JA(0)` | Comando lógico da sirene |
| `JA(1)` | Comando lógico do gerador de névoa |
| `JA(2)` | Comando lógico da contramedida |
| `JA(3)` | Indicação/watchdog de comunicação |

Esses sinais devem acionar somente interfaces adequadas de baixa tensão; não devem alimentar cargas diretamente.
