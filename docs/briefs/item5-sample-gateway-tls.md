> **Status: concluído.** Sample `samples/GatewaySeguro/` (`ServicoLocal` + `GatewaySeguro`
> + `ClienteRemoto`, com `Gateway.Protocolo.pas` e `Gateway.Nucleo.pas`) existe, está
> registrado nos dois grupos de build e descrito no `README.md`. Duas diferenças em
> relação ao desenho abaixo, ambas deliberadas: o `IDENT|` é enviado **dentro do
> `Conectar`**, antes de o par entrar no dicionário (registrar primeiro abriria uma
> janela em que uma mensagem repassada chegaria ao serviço local antes da identidade); e
> tanto o gateway quanto o `ServicoLocal` usam `pdmSerialized`, porque em `pdmPool` não há
> ordem garantida nem entre `OnClientConnected` e o primeiro `OnMessage` da mesma conexão,
> nem entre duas mensagens dela — o custo e a saída estão comentados no código. Para a
> verificação 4 foi acrescentado um **segundo cliente legítimo** à PKI de teste
> (`caixa_*`, `CN=caixa-02`): `cli`, `rogue`, `selfsigned` e `gemea` compartilham o mesmo
> `CN` de propósito, então não havia duas identidades aceitas e distintas. Mantido como
> registro do racional.

# Brief: sample de gateway `ptTls` → `ptLocal`

**Modelo sugerido:** opus (threading não trivial: duas instâncias da lib se chamando).
**Origem:** sessão do sample `PontosECaixas` — levantamento do que os 11 samples
ainda não demonstram.
**Status:** concluído.

## Por que este sample existe

Em **todos** os samples de hoje um processo é servidor **ou** cliente. `ChatVcl` e
`PontosECaixas` até declaram os dois campos, mas só instanciam um por vez. Nenhum
sample mostra `TPipeServer` e `TPipeClient` **vivos ao mesmo tempo**, e muito menos
com transportes diferentes em cada ponta.

Os samples atuais provam que *o alcance é uma property*. Este prova outra coisa:
que **os alcances se compõem**. É a diferença entre trocar de transporte e usar
dois ao mesmo tempo, de propósito.

O caso de uso é o que as pessoas realmente têm: um serviço que só fala IPC local e
nunca vai aprender TLS, e a necessidade de expô-lo à rede com autenticação.

## Topologia

```
[ClienteRemoto]  --ptTls + mTLS-->  [GatewaySeguro]  --ptLocal-->  [ServicoLocal]
   outra máquina                    autentica, repassa            não sabe o que é TLS
```

Três executáveis console em `samples/GatewaySeguro/`, no estilo de
`samples/DespachoTarefas` (classe com callbacks `of object`, log sob
`TCriticalSection`, `Readln` encerra):

- `ServicoLocal.dpr` — `TPipeServer` em `ptLocal`. Serviço bobo (eco com carimbo),
  mas que **registra a identidade do chamador** que o gateway informou.
- `GatewaySeguro.dpr` — o miolo. `TPipeServer` em `ptTls` + N `TPipeClient` em `ptLocal`.
- `ClienteRemoto.dpr` — `TPipeClient` em `ptTls`, apresentando certificado.

## A lição central (escrever no cabeçalho do gateway)

O gateway autentica por mTLS e sabe quem é o par: `TryClientIdentity` devolve o
`CommonName` **já validado contra a CA** — certificado com CN forjado não chega ali,
é recusado no handshake. Do outro lado, `ptLocal` não tem TLS e portanto não tem
identidade nenhuma. Então o gateway precisa *contar* ao serviço local quem está
chamando.

**Por que o serviço local deveria acreditar?** Porque `ptLocal` herda o controle de
acesso do sistema operacional: só processos daquela máquina alcançam aquele pipe, e
na prática o gateway é a única coisa que fala com ele.

O contra-exemplo tem que estar escrito: se o `ServicoLocal` estivesse em `ptTcp`
ouvindo em `0.0.0.0`, o esquema inteiro cai — qualquer um pula o gateway e se declara
quem quiser. **A segurança do gateway não vem do gateway; vem do alcance do
transporte de trás.**

## Desenho

### O par de conexões

1:1 — cada conexão remota abre uma conexão local própria. Multiplexar num cliente só
exige correlação própria e é outro sample.

```pascal
TGatewayPar = class
private
  FGateway: TGatewaySeguro;
  FConnRemota: TPipeConnectionId;
  FLocal: TPipeClient;        // ptLocal, deste par
  FIdentidade: string;        // CommonName vindo do mTLS
  FRefs: Integer;             // atômico
  FMensagens: Integer;
  FDesde: TDateTime;
public
  // Handlers do cliente local: cada PAR é o dono dos seus próprios handlers.
  procedure LocalMessage(Sender: TObject; AConnId: TPipeConnectionId; const AData: TBytes);
  procedure LocalDisconnected(Sender: TObject; AConnId: TPipeConnectionId);
  procedure AddRef;
  procedure Release;
end;
```

**Por que o par é o dono dos handlers, e não o gateway:** sem métodos anônimos
(proibidos, ver CLAUDE.md), um handler único no gateway teria que descobrir de qual
par veio a mensagem mapeando `Sender` → par, com mais um dicionário. Dando a cada par
os próprios métodos `of object`, o `Self` já é a resposta. É o mesmo motivo pelo qual
os work items do pool carregam dados em campos.

### Invariantes de lock (cabeçalho da unit, molde `Pipes.Server.pas:11-36`)

- `FParesLock` protege o dicionário `FPares` e nada mais.
- Ordem "de fora pra dentro": `FParesLock` → componente da lib. **Nunca** chamar
  `SendBytes`, `Disconnect`, `DisconnectClient` ou `Free` segurando `FParesLock`.
- Consulta = pegar o par sob o lock **com `AddRef`**, sair do lock, agir, `Release`.
  É exatamente o que `TPipeServer.Broadcast` faz com o snapshot de conexões.
- Remover do dicionário é o **ato de posse** do teardown: quem removeu é quem
  destrói. Morte da ponta remota, morte da ponta local e o Stop do gateway disputam
  essa remoção.

### O perigo real: teardown dentro de callback

`TPipeClient.Disconnect` é **síncrono** — faz join da reader thread e `DrainInFlight`.
Se ele for chamado de dentro de um callback que está rodando **no pool**, e houver
outro callback daquele mesmo cliente enfileirado atrás no mesmo pool, o worker atual
espera por um work item que nunca vai rodar. Com pool de um worker, é deadlock certo.

**Regra do sample: nenhum `Free`/`Disconnect` de par acontece dentro de callback.**
O callback só *marca* o par para remoção e entrega a um ceifador — um `TThread`
simples com fila e evento, no espírito do `QueueCleanup` da lib. O cabeçalho tem que
explicar isto; é a parte do sample que ensina mais.

### Fluxo

**Entrada remota** (`Srv.OnClientConnected`):
1. `Srv.TryClientIdentity(connId, ident)`. Com `CaFile` preenchido, `False` aqui
   significa configuração errada, não "espere" — abortar e logar alto.
2. Criar `TPipeClient(EnderecoLocal, ptLocal)`, fiar os handlers **do par**, `Connect`.
3. Falhou o `Connect`? Mandar recusa de aplicação ao remoto **com motivo** e
   `DisconnectClient`. Ver "duas camadas de conectado", abaixo.
4. Registrar o par; mandar ao serviço local o frame de identidade.

**Remoto → local** (`Srv.OnMessage`): achar o par (AddRef fora do lock),
`par.FLocal.SendBytes(AData)`, `Release`. `EPipeError` ⇒ marcar par para teardown.

**Local → remoto** (`TGatewayPar.LocalMessage`): `FGateway.Servidor.SendBytes(FConnRemota, AData)`.

**Mortes:** ponta local cai ⇒ derruba a remota (com motivo, se der tempo);
ponta remota cai (`OnClientDisconnected`) ⇒ marca o par, ceifador destrói o cliente local.

### Protocolo

Unit `Gateway.Protocolo.pas` mínima, porque **o gateway não entende o protocolo da
aplicação** — e isso é uma qualidade, não uma limitação. Só duas mensagens dele:

- `IDENT|<commonName>` — gateway → serviço local, primeira mensagem da conexão local.
- `RECUSADO|<motivo>` — gateway → remoto, quando a recusa é de aplicação.

Todo o resto trafega **opaco** (`TBytes` sem inspeção). O `ServicoLocal` responde
carimbando quem pediu, para a prova de identidade ficar visível.

### Fora de escopo v1 (documentar, não esconder)

Relay de `Request`/`RequestText`. O `OnRequest` do gateway roda no pool e teria que
devolver a resposta ali; o caminho natural (um `Request` síncrono ao serviço local
dentro do handler) **prende um worker do pool** durante a ida e volta, e com chamadas
concorrentes suficientes o pool esgota. Fica registrado no cabeçalho como limite
conhecido, com a saída apontada (correlação assíncrona), no mesmo tom com que o
`ServicoInstavel` assume que simula falha de propósito.

## Duas camadas de "conectado"

Vale um parágrafo no cabeçalho e uma linha no README: o cliente remoto pode
**conectar com sucesso e se autenticar com sucesso** e ainda assim não ter serviço,
porque o `ServicoLocal` está fora do ar. Handshake TLS concluído não é o mesmo que
sessão útil. Por isso a recusa carrega motivo em vez de ser um socket fechado calado.

## Fiação TLS

Referência canônica: `docs/briefs/item4-sample-mtls.md` e
`tests/Integration/Pipes.TlsTests.pas`. Reaproveitar a PKI de teste de `tests/pki`
(`srv.pfx`/`srv_cert.pem` no gateway, `cli`/`rogue`/`selfsigned` no cliente remoto).
`CaFile` no gateway é o que **liga** o mTLS. Imprimir `PipeTlsBackendInfo` na subida.

`MaxClients` no gateway: cada entrada abre uma saída, então o teto é de recurso
**dobrado**. Dizer isso no comentário.

## Painel do gateway

O console imprime a tabela viva — é o que qualquer um vai querer em produção:

```
[remota 3] pdv-loja-001  ->  local #7   (2m14s, 431 msgs)
[remota 5] caixa-02      ->  local #8   (12s, 3 msgs)
```

## Passos que se esquece (obrigatórios — ver CLAUDE.md)

1. Registrar os **três** `.dproj` em `Pipes.groupproj` (Projects + Targets +
   CallTarget de Build/Clean/Make) e os três `.lpi` em `Pipes.lpg` (Target com
   BuildModes). Sem isso o sample não entra no build do grupo.
2. Linux exige `-dPIPES_OPENSSL` (não há SChannel lá); documentar no cabeçalho dos
   `.dpr`, como em `EchoServer.dpr`.
3. Uma entrada no `README.md`, na lista de samples.
4. Nada de métodos anônimos, `System.Threading` ou inline vars.

## Verificação

O que dá valor ao sample é a metade que **recusa** — mesma régua do `EchoSeguro`:

1. Cliente remoto **sem** certificado ⇒ recusado no gateway **e o `ServicoLocal` não
   registra absolutamente nada**. É a prova de que não vazou nada para trás.
2. Certificado `rogue` (outra CA) e `selfsigned` ⇒ recusados, com vereditos
   distintos entre si (ver `docs/ARQUITETURA.md` §7, nota sobre `VerifyClientChain`).
3. **`ServicoLocal` fora do ar** ⇒ o remoto autentica com sucesso e recebe
   `RECUSADO|` com motivo. As duas camadas de "conectado".
4. **Dois clientes remotos simultâneos, com certificados diferentes** ⇒ o
   `ServicoLocal` carimba a identidade certa em cada resposta. Cruzamento de
   identidade seria o pior bug possível num gateway; este é o teste que importa.
5. Matar o `ServicoLocal` no meio do tráfego ⇒ as conexões remotas caem com motivo,
   sem vazar handle/fd. Repetir ~50 vezes e conferir a contagem, como a suíte de
   integração já faz nas quedas abruptas.
6. Matar um cliente remoto ⇒ a conexão local correspondente some (espelhamento de
   ciclo de vida), e as outras seguem intactas.
7. Encerrar o gateway sob tráfego ⇒ conclui em < 2s, sem deadlock (mesma régua do M7).

Compilar nos dois: `lazbuild` de cada `.lpi` e build do grupo no Delphi.
