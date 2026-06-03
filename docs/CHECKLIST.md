# Checklist atualizado do projeto

## Feito

- [x] Central FPGA com MEF em VHDL preparada.
- [x] Controle de armado/desarmado e display de estados.
- [x] Temporizador e indicação visual de zonas.
- [x] Interface digital FPGA ↔ ESP32 definida.
- [x] Correção da leitura de armado e da Zona 2 no ESP32.
- [x] Firmware ESP32 inicial com leitura e envio de ACK preparado.
- [x] Circuito da cerca/contramedida informado como montado.

## Validar agora — prioridade máxima

- [ ] Testar zonas 1 a 5 individualmente e salvar prints do Serial Monitor.
- [ ] Testar duas zonas simultâneas.
- [ ] Confirmar que o `LED11` acende quando o ESP32 envia ACK.
- [ ] Confirmar que o `LED10` acende sem ACK, comprovando o watchdog.
- [ ] Validar acionamento seguro da contramedida pronta pela saída lógica da FPGA.
- [ ] Registrar fotos e resultados dos testes.

## Montagem física pendente

- [ ] Montar o gerador de névoa/fumaça segura.
- [ ] Instalar sensores reais nas cinco zonas.
- [ ] Utilizar ao menos quatro tipos de sensores.
- [ ] Fixar placas, cabos, fontes e atuadores na maquete.
- [ ] Garantir que a Basys 3 possa ser encaixada e removida.

## Software e IoT pendentes

- [ ] Conectar o ESP32 ao Wi-Fi.
- [ ] Escolher e justificar broker/plataforma MQTT.
- [ ] Publicar status e eventos com zonas violadas.
- [ ] Criar dashboard acessível em padrão mobile.
- [ ] Implementar dois canais de alerta.
- [ ] Armazenar eventos em banco de dados.
- [ ] Gerar estatísticas de uso/disparos.

## Entrega pendente

- [ ] Atualizar documentação técnica com evidências reais.
- [ ] Publicar arquivos finais no GitHub.
- [ ] Gravar vídeo demonstrativo e inserir link no repositório.
- [ ] Preparar pitch e demonstração final.
