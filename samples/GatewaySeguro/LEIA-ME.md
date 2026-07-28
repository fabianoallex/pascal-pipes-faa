# GatewaySeguro — como rodar

Roteiro de execução dos três executáveis deste sample. O **racional** (de onde vem a
segurança do desenho, invariantes de lock, por que nenhum `Free` acontece dentro de
callback) está no cabeçalho de [`Gateway.Nucleo.pas`](Gateway.Nucleo.pas) — não é repetido
aqui de propósito, para as duas cópias não divergirem.

```
[ClienteRemoto]  --ptTls + mTLS-->  [GatewaySeguro]  --ptLocal-->  [ServicoLocal]
   outra máquina                    autentica, repassa            não sabe o que é TLS
```

Este roteiro também serve de **checklist de regressão**: é o que se re-executa depois de
mexer no gateway. As saídas abaixo são reais, de uma execução completa no Windows/SChannel.

## Compilar

- **Delphi:** abrir `Pipes.groupproj` na raiz e buildar (os três projetos já estão
  registrados). Os `.exe` saem em `samples\GatewaySeguro\Win64\Debug\`.
- **FPC/Lazarus (Windows):** `lazbuild ServicoLocal.lpi`, `lazbuild GatewaySeguro.lpi`,
  `lazbuild ClienteRemoto.lpi`. Os `.exe` saem na própria pasta do sample.
- **FPC (Linux):** o gateway e o cliente exigem `-dPIPES_OPENSSL` (não há SChannel lá); o
  `ServicoLocal` não usa TLS e dispensa. Linhas completas no cabeçalho de cada `.dpr`.

As credenciais vêm da PKI de **teste** versionada em [`tests/pki/`](../../tests/pki/LEIA-ME.md),
que os executáveis localizam sozinhos subindo a partir da própria pasta. Ela não tem valor de
segurança — nunca reaproveitar fora deste sample e da suíte.

## A — montar (4 terminais, todos na pasta dos `.exe`)

| # | Comando | Espere ver |
|---|---|---|
| 1 | `ServicoLocal.exe` | `servico local escutando em "pipes_faa_servico_local" (ptLocal, sem TLS)` |
| 2 | `GatewaySeguro.exe` | `gateway no ar: 0.0.0.0:5000 (ptTls + mTLS) -> "pipes_faa_servico_local" (ptLocal)` |
| 3 | `ClienteRemoto.exe` | `sessao TLS aberta com o gateway.` |
| 4 | `ClienteRemoto.exe 127.0.0.1:5000 caixa` | idem, com `identidade: caixa` |

O `backend TLS:` vazio logo após subir o gateway é esperado: o `Listen` é não-blocante e não
negocia nada sozinho, então a informação do backend só existe depois do primeiro handshake —
o gateway a imprime de novo quando o primeiro cliente autentica.

A ordem entre os terminais 1 e 2 não importa; o gateway só procura o serviço local quando
um cliente remoto chega. Terminais 3 e 4 exigem o gateway no ar.

## B — a identidade não cruza

Digite texto nos terminais 3 e 4, alternando. Cada resposta tem que voltar carimbada com o
`CommonName` do certificado **daquele** cliente:

```
terminal 3:  servico local respondeu: eco[pdv-loja-001 @ 16:53:45]: 33
terminal 4:  servico local respondeu: eco[caixa-02 @ 16:53:43]: 44
```

E o terminal 1 mostra as duas conexões com identidades diferentes, cada mensagem no par
certo mesmo quando chegam intercaladas:

```
[conn 1] o gateway diz que quem chama e "pdv-loja-001"
[conn 2] o gateway diz que quem chama e "caixa-02"
[conn 1] pdv-loja-001 pediu: 33
[conn 2] caixa-02 pediu: 44
```

`list` no terminal 2 mostra a tabela viva:

```
  [remota 1] pdv-loja-001     ->  local #1   (2m14s, 4 msgs)
  [remota 2] caixa-02         ->  local #2   (1m58s, 3 msgs)
```

Cruzamento de identidade seria o pior bug possível num gateway; esta é a checagem que
importa.

## C — as recusas (a metade que dá valor ao sample)

Com os terminais 3 e 4 ainda conectados, rode num quinto terminal, uma de cada vez:

```
ClienteRemoto.exe 127.0.0.1:5000 rogue
ClienteRemoto.exe 127.0.0.1:5000 selfsigned
ClienteRemoto.exe 127.0.0.1:5000 nenhum
```

O gateway recusa as três, com vereditos **distintos** entre si — se todas dessem o mesmo
erro, a validação não estaria olhando a cadeia:

```
[remota 3] erro (handshake/mTLS recusado?): mTLS: cadeia do cliente invalida (dwErrorStatus 0x00010000)
[remota 4] erro (handshake/mTLS recusado?): mTLS: certificado de cliente nao encadeia ate a CA configurada
[remota 5] erro (handshake/mTLS recusado?): handshake TLS (servidor) falhou (0x00090317)
```

**O que prova o desenho não é isso — é o terminal 1 não ganhar uma única linha nova**
enquanto as três tentativas acontecem. Nenhuma conexão local foi aberta, então nada vazou
para trás do gateway. Os terminais 3 e 4 seguem funcionando o tempo todo.

No SChannel os clientes `rogue` e `selfsigned` imprimem `sessao TLS aberta com o gateway`
antes de cair: a cadeia do cliente é conferida **depois** do handshake. Por isso a mensagem
não diz "autenticado" — a prova de que a sessão serve para alguma coisa é a primeira
resposta do serviço local, não o evento de conexão. No OpenSSL a recusa acontece dentro do
próprio handshake e o `Connect` falha; os dois vereditos estão certos.

## D — as duas camadas de "conectado"

**Serviço morre no meio:** aperte Enter no terminal 1. Os dois clientes recebem o motivo e
caem; o gateway continua no ar:

```
*** RECUSADO PELO GATEWAY: servico local encerrou a conexao
    (a sessao TLS estava valida: esta recusa e de APLICACAO. Handshake
     concluido nao e o mesmo que ter servico do outro lado.)
```

**Serviço já fora quando o cliente chega:** com o terminal 1 fechado, rode o
`ClienteRemoto.exe`. O handshake mTLS passa e mesmo assim vem
`RECUSADO| servico local indisponivel: timeout (2000 ms) conectando ao pipe ...`.

É a lição do sample: handshake TLS concluído não é o mesmo que sessão útil — e por isso a
recusa carrega motivo em vez de ser um socket fechado calado.

Duas linhas de `saiu (0 no total)` seguidas no terminal 1 não são contagem errada: a lib
remove a conexão do registro *antes* de disparar `OnClientDisconnected` (a remoção é o ato de
posse do teardown), então quando as duas morrem juntas o primeiro handler já vê zero.

## E — mortes e encerramento

- **Matar um cliente remoto** (fechar a janela, ou `taskkill`): no terminal 1 só a conexão
  **dele** sai; a outra continua respondendo. Espelhamento de ciclo de vida.
- **Encerrar o gateway sob tráfego:** com os clientes mandando mensagens, `sair` no terminal
  2. Tem que concluir na hora — a régua do M7 é < 2 s; a medição desta sessão deu 223 ms com
  três clientes em flood. Os clientes recebem `RECUSADO| gateway encerrando`.
- **Quedas abruptas repetidas:** 50 ciclos de cliente conectando e sendo morto deixam a
  contagem de conexões balanceada nos dois lados (53 abertas / 53 fechadas, gateway e
  serviço). O crescimento de handles observado no processo do gateway acompanha o do
  `EchoSeguroServer` (biblioteca pura) e é do caminho `ptTls`/SChannel, não deste sample.

## Parâmetros

```
ServicoLocal.exe   [nome-do-pipe]                    (padrão pipes_faa_servico_local)
GatewaySeguro.exe  [endereço-tls] [pipe-local] [max-remotos]
                                                     (padrões 0.0.0.0:5000,
                                                      pipes_faa_servico_local, 8)
ClienteRemoto.exe  [endereço] [identidade]           (padrões 127.0.0.1:5000, cli)
```

Identidades aceitas em `ClienteRemoto`: `cli` e `caixa` entram; `rogue`, `selfsigned` e
`nenhum` são recusados. `MaxClients` no gateway é teto de recurso **dobrado**: cada conexão
remota aceita abre uma conexão local própria.
