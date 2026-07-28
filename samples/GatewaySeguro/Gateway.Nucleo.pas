unit Gateway.Nucleo;

{$I pipes.inc}

{ Miolo do gateway ptTls -> ptLocal: um TPipeServer em ptTls (com mTLS) e N
  TPipeClient em ptLocal, VIVOS AO MESMO TEMPO no mesmo processo. E' o unico
  sample da lib em que as duas pontas da API coexistem, e com transportes
  diferentes em cada lado — os outros provam que o alcance e' uma property;
  este prova que os alcances se COMPOEM.

  ---------------------------------------------------------------------------
  A LICAO CENTRAL: de onde vem a seguranca deste desenho
  ---------------------------------------------------------------------------
  O gateway autentica por mTLS e sabe quem e' o par: TryClientIdentity devolve
  o CommonName JA VALIDADO contra a CA configurada em CaFile — um certificado
  com CN forjado nao chega ali, e' recusado no handshake. Do outro lado, ptLocal
  nao tem TLS e portanto nao tem identidade nenhuma. Entao o gateway precisa
  CONTAR ao servico local quem esta chamando (frame IDENT|, ver
  Gateway.Protocolo).

  Por que o servico local deveria acreditar nesse "IDENT|"? Porque ptLocal
  herda o controle de acesso do SISTEMA OPERACIONAL: so processos daquela
  maquina alcancam aquele pipe/socket, e na pratica o gateway e' a unica coisa
  que fala com ele.

  O contra-exemplo importa mais que a regra: se o servico local estivesse em
  ptTcp ouvindo em 0.0.0.0, o esquema inteiro cai — qualquer um na rede pula o
  gateway, abre a conexao direto e se declara quem quiser, porque nada mais
  confere o IDENT|. A SEGURANCA DO GATEWAY NAO VEM DO GATEWAY; VEM DO ALCANCE
  DO TRANSPORTE DE TRAS.

  ---------------------------------------------------------------------------
  DUAS CAMADAS DE "CONECTADO"
  ---------------------------------------------------------------------------
  O cliente remoto pode conectar com sucesso E se autenticar com sucesso e
  ainda assim nao ter servico, porque o ServicoLocal esta fora do ar. Handshake
  TLS concluido nao e' o mesmo que sessao util. Por isso a recusa carrega motivo
  (RECUSADO|<motivo>) em vez de ser um socket fechado calado: o operador do
  outro lado precisa distinguir "meu certificado foi recusado" de "o servico de
  tras caiu".

  ---------------------------------------------------------------------------
  INVARIANTES DE LOCK E POSSE (violar = deadlock/use-after-free)
  ---------------------------------------------------------------------------
  - FParesLock protege FPares (e o FSeqLocal) e NADA MAIS.
  - Ordem "de fora pra dentro": FParesLock -> componente da lib. NUNCA chamar
    SendBytes, Disconnect, DisconnectClient ou Free segurando FParesLock.
  - Consulta = pegar o par sob o lock COM AddRef, sair do lock, agir, Release.
    E' exatamente o que TPipeServer.Broadcast faz com o snapshot de conexoes.
  - REMOVER do dicionario e' o ATO DE POSSE do teardown (Ceifar): quem removeu
    e' quem solta a referencia do registro. Morte da ponta remota, morte da
    ponta local e o Parar do gateway disputam essa remocao; so um ganha.
  - Cada par tem refcount: 1 do registro + 1 transitorio por consulta. Ao zerar,
    o par NAO se libera sozinho — vai para a fila do ceifador.

  ---------------------------------------------------------------------------
  O PERIGO REAL: TEARDOWN DENTRO DE CALLBACK (a parte que mais ensina)
  ---------------------------------------------------------------------------
  TPipeClient.Disconnect e' SINCRONO: faz join da reader thread e DrainInFlight.
  Se ele rodar de dentro de um callback que esta executando NO POOL, e houver
  outro callback daquele mesmo cliente enfileirado atras no MESMO pool, o worker
  atual espera por um work item que nunca vai rodar. Com pool de um worker
  (pdmSerialized), e' deadlock certo.

  REGRA DESTE SAMPLE: nenhum Free/Disconnect de par acontece dentro de callback.
  O callback so' MARCA o par para remocao (Ceifar) e a destruicao acontece no
  ceifador — um TThread simples com fila e evento, no espirito do QueueCleanup
  da lib. Por isso TGatewayPar.Release nunca libera inline: ele enfileira.

  ---------------------------------------------------------------------------
  POR QUE OS HANDLERS SAO DO PAR, E NAO DO GATEWAY
  ---------------------------------------------------------------------------
  Sem metodos anonimos (proibidos, ver CLAUDE.md), um handler unico no gateway
  teria que descobrir de qual par veio a mensagem mapeando Sender -> par, com
  mais um dicionario e mais um lock. Dando a cada par os proprios metodos
  'of object', o Self JA E' a resposta. E' o mesmo motivo pelo qual os work
  items do pool carregam dados em campos.

  ---------------------------------------------------------------------------
  FORA DE ESCOPO NESTA VERSAO (documentado, nao escondido)
  ---------------------------------------------------------------------------
  Relay de Request/RequestText. O OnRequest do gateway roda no pool e teria que
  devolver a resposta ali; o caminho natural (um Request sincrono ao servico
  local dentro do handler) PRENDE UM WORKER do pool durante a ida e volta, e com
  chamadas concorrentes suficientes o pool esgota. A saida seria correlacao
  assincrona: guardar (corrId remoto -> conexao remota), mandar a pergunta ao
  servico local como mensagem e casar a resposta quando ela voltar, sem
  bloquear worker nenhum. Nao esta implementado de proposito. }

interface

uses
  SysUtils,
  Classes,
  SyncObjs,
  Generics.Collections,
  Pipes.Types,
  Pipes.Threading,
  Pipes.Framing,
  Pipes.Base,
  Pipes.Client,
  Pipes.Server,
  Gateway.Protocolo;

type
  TGatewaySeguro = class;

  TGatewayLogEvent = procedure(Sender: TObject; const AMsg: string) of object;

  { Uma linha do painel. Snapshot: copiado sob o lock, impresso fora dele. }
  TGatewayLinhaPainel = record
    ConnRemota: TPipeConnectionId;
    Identidade: string;
    LocalSeq: Integer;
    Desde: TDateTime;
    Mensagens: Integer;
  end;

  TGatewayPainel = array of TGatewayLinhaPainel;

  { O par de conexoes: 1:1 — cada conexao remota abre uma conexao local propria.
    Multiplexar tudo num cliente local so' exigiria correlacao propria (o
    servico local nao saberia de quem e' cada resposta) e e' outro sample.

    Ciclo de vida: criado no OnClientConnected do servidor TLS, destruido SEMPRE
    pelo ceifador — nunca dentro de um callback (ver o cabecalho da unit). }
  TGatewayPar = class
  private
    FGateway: TGatewaySeguro;
    FConnRemota: TPipeConnectionId;
    FLocal: TPipeClient;    // ptLocal, exclusivo deste par
    FIdentidade: string;    // CommonName vindo do mTLS, ja' validado
    FLocalSeq: Integer;     // numero de exibicao no painel ("local #7")
    FRefs: Integer;         // atomico: 1 do registro + 1 por consulta
    FMensagens: Integer;    // atomico
    FDesde: TDateTime;
    FCaindo: Integer;       // atomico: 1 = teardown ja' pedido
    // Handlers do cliente local: cada PAR e' o dono dos seus proprios handlers,
    // entao Self ja' diz de qual par veio o evento.
    procedure LocalMessage(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure LocalDisconnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure LocalError(Sender: TObject; AConnId: TPipeConnectionId;
      const AError: string);
    /// Derruba a ponta remota COM MOTIVO e marca o par para o ceifador.
    /// Idempotente (CAS em FCaindo): as duas mortes podem chegar juntas.
    procedure Derrubar(const AMotivo: string);
  public
    constructor Create(AGateway: TGatewaySeguro; AConnRemota: TPipeConnectionId;
      const AIdentidade: string);
    /// SO' o ceifador chega aqui. Ver o cabecalho da unit.
    destructor Destroy; override;
    /// Abre a conexao local e manda o IDENT|. False + motivo se nao der.
    function Conectar(out AMotivo: string): Boolean;
    /// Remoto -> local. O payload e' OPACO: o gateway nao inspeciona nada.
    procedure Repassar(const AData: TBytes);
    procedure AddRef;
    /// Ao zerar, o par vai para a FILA DO CEIFADOR — nunca se libera inline.
    procedure Release;
  end;

  { Ceifador: o unico lugar do processo onde um TGatewayPar e' destruido (e,
    portanto, onde TPipeClient.Disconnect roda). Existe exatamente para tirar
    esse Disconnect sincrono de dentro dos callbacks do pool. }
  TGatewayCeifador = class(TThread)
  private
    FLock: TCriticalSection;
    FFila: TQueue<TGatewayPar>;
    FSinal: TEvent;
    procedure Drenar;
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Enfileirar(APar: TGatewayPar);
    /// Termina, acorda, faz join e drena o que tiver sobrado na corrida final.
    procedure Encerrar;
  end;

  TGatewaySeguro = class
  private
    FSrv: TPipeServer;            // ptTls + mTLS, a ponta de fora
    FEnderecoTls: string;
    FEnderecoLocal: string;
    FMaxRemotos: Integer;
    FPares: TDictionary<TPipeConnectionId, TGatewayPar>;
    FParesLock: TCriticalSection; // protege FPares e FSeqLocal, e nada mais
    FCeifador: TGatewayCeifador;
    FSeqLocal: Integer;           // sob FParesLock
    FAtivo: Boolean;              // so' a main thread mexe (Iniciar/Parar)
    FParando: Integer;            // atomico: 1 = nao aceitar mais pares novos
    FBackendLogado: Boolean;
    FOnLog: TGatewayLogEvent;
    procedure Log(const AMsg: string);
    /// Consulta com AddRef sob o lock; o chamador da' Release FORA do lock.
    function AcharPar(AConnId: TPipeConnectionId): TGatewayPar;
    /// Esvazia o dicionario (ato de posse) e solta a referencia do registro de
    /// cada par. AAvisar manda RECUSADO| antes, para o remoto saber o motivo.
    procedure SoltarTodosOsPares(AAvisar: Boolean);
    /// Recusa de APLICACAO: manda o motivo e derruba a conexao remota.
    procedure RecusarRemoto(AConnId: TPipeConnectionId; const AMotivo: string);
    function NomeDe(AConnId: TPipeConnectionId): string;
    // Handlers do servidor TLS.
    procedure SrvConnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure SrvDisconnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure SrvMessage(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure SrvError(Sender: TObject; AConnId: TPipeConnectionId;
      const AError: string);
    /// Ato de posse do teardown: remove do dicionario e solta a referencia do
    /// registro. Chamavel de dentro de callback (nao libera nada inline).
    procedure Ceifar(APar: TGatewayPar);
  public
    constructor Create(const AEnderecoTls, AEnderecoLocal: string;
      AMaxRemotos: Integer);
    destructor Destroy; override;
    /// Sobe o ceifador e poe o servidor TLS no ar. APkiDir termina com
    /// separador de caminho.
    procedure Iniciar(const APkiDir: string);
    /// Sincrono e idempotente.
    procedure Parar;
    function Painel: TGatewayPainel;
    property Servidor: TPipeServer read FSrv;
    property OnLog: TGatewayLogEvent read FOnLog write FOnLog;
  end;

implementation

{ ---------------------------------------------------------------- ceifador }

constructor TGatewayCeifador.Create;
begin
  // Campos ANTES do inherited: a thread ja' sobe rodando e o Execute toca
  // FSinal/FFila/FLock na primeira instrucao. E' o idioma da propria lib
  // (Pipes.Threading.pas:296-301) e existe por compatibilidade: criar suspensa
  // e chamar Start depois compila nos dois compiladores, mas no Delphi levanta
  // EThread ("Cannot call Start on a running or suspended thread") em runtime.
  FLock := TCriticalSection.Create;
  FFila := TQueue<TGatewayPar>.Create;
  FSinal := TEvent.Create(nil, False, False, ''); // auto-reset
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TGatewayCeifador.Destroy;
begin
  Encerrar;
  inherited Destroy; // join (a thread ja' saiu)
  FSinal.Free;
  FFila.Free;
  FLock.Free;
end;

procedure TGatewayCeifador.Enfileirar(APar: TGatewayPar);
begin
  FLock.Enter;
  try
    FFila.Enqueue(APar);
  finally
    FLock.Leave;
  end;
  FSinal.SetEvent;
end;

procedure TGatewayCeifador.Drenar;
var
  LPar: TGatewayPar;
begin
  while True do
  begin
    LPar := nil;
    FLock.Enter;
    try
      if FFila.Count > 0 then
        LPar := FFila.Dequeue;
    finally
      FLock.Leave;
    end;
    if LPar = nil then
      Break;
    // AQUI, e so' aqui, roda o TPipeClient.Disconnect sincrono do par: nesta
    // thread ele nao pode esperar por um work item enfileirado atras de si.
    LPar.Free;
  end;
end;

procedure TGatewayCeifador.Execute;
begin
  repeat
    // O timeout cobre a corrida "Enfileirar entre o teste de Terminated e o
    // Wait"; o SetEvent do Enfileirar/Encerrar e' o caminho normal.
    FSinal.WaitFor(200);
    Drenar;
  until Terminated;
  Drenar; // ultima passada: quem entrou na fila durante o encerramento
end;

procedure TGatewayCeifador.Encerrar;
begin
  Terminate;
  FSinal.SetEvent;
  WaitFor; // idempotente: sobre uma thread ja' encerrada, volta na hora
  // Drena SEMPRE, inclusive nas chamadas posteriores ao join: dai em diante
  // este metodo e' o proprio ceifador, rodando na thread de quem chamou (que
  // nunca e' um callback do pool — Parar/Destroy vem da main thread).
  Drenar;
end;

{ --------------------------------------------------------------------- par }

constructor TGatewayPar.Create(AGateway: TGatewaySeguro;
  AConnRemota: TPipeConnectionId; const AIdentidade: string);
begin
  inherited Create;
  FGateway := AGateway;
  FConnRemota := AConnRemota;
  FIdentidade := AIdentidade;
  FDesde := Now;
  FRefs := 1; // referencia de quem criou (vira a do registro, se registrar)
end;

destructor TGatewayPar.Destroy;
begin
  // Disconnect e' SINCRONO (join da reader thread + DrainInFlight). So chega
  // aqui pela fila do ceifador — ver o cabecalho da unit.
  FLocal.Free;
  inherited Destroy;
end;

procedure TGatewayPar.AddRef;
begin
  PipeAtomicInc(FRefs);
end;

procedure TGatewayPar.Release;
begin
  if PipeAtomicDec(FRefs) = 0 then
    FGateway.FCeifador.Enfileirar(Self);
end;

function TGatewayPar.Conectar(out AMotivo: string): Boolean;
begin
  AMotivo := '';
  Result := False;
  FLocal := TPipeClient.Create(FGateway.FEnderecoLocal, ptLocal);
  // Sem AutoReconnect de proposito: a vida da conexao local ESPELHA a da
  // remota. Se o servico local cai, o certo e' o cliente remoto saber disso
  // (com motivo) — nao ficar preso num gateway que finge estar servindo.
  FLocal.OnMessage := LocalMessage;
  FLocal.OnDisconnected := LocalDisconnected;
  FLocal.OnError := LocalError;
  try
    FLocal.Connect(2000);
    // O IDENT| vai AQUI, antes de o par entrar no dicionario: enquanto ele nao
    // esta registrado, nenhuma mensagem remota consegue ser repassada, entao a
    // identidade e' garantidamente o primeiro byte de aplicacao que o servico
    // local ve nesta conexao.
    FLocal.SendBytes(GatewayIdent(FIdentidade));
    Result := True;
  except
    on E: EPipeError do
      AMotivo := E.Message;
  end;
end;

procedure TGatewayPar.Repassar(const AData: TBytes);
begin
  try
    FLocal.SendBytes(AData); // opaco: o gateway nao entende o protocolo
    PipeAtomicInc(FMensagens);
  except
    on E: EPipeError do
      Derrubar('servico local indisponivel: ' + E.Message);
  end;
end;

procedure TGatewayPar.Derrubar(const AMotivo: string);
begin
  // Uma vez so': a morte da ponta local e a da ponta remota podem chegar
  // juntas, e as duas passam por aqui.
  if PipeAtomicCompareExchange(FCaindo, 1, 0) <> 0 then
    Exit;
  FGateway.Log(Format('[remota %d] %s: derrubando (%s)',
    [FConnRemota, FIdentidade, AMotivo]));
  try
    FGateway.FSrv.SendBytes(FConnRemota, GatewayRecusado(AMotivo));
  except
    // "com motivo, se der tempo": o remoto pode ja' ter sumido.
    on E: EPipeError do
      ;
  end;
  // ASSINCRONO (CloseAbort + limpeza no pool): pode ser chamado de dentro de um
  // callback, ao contrario de Stop/Disconnect.
  FGateway.FSrv.DisconnectClient(FConnRemota);
  // Marca para o ceifador. NAO libera nada aqui: ver o cabecalho da unit.
  FGateway.Ceifar(Self);
end;

procedure TGatewayPar.LocalMessage(Sender: TObject; AConnId: TPipeConnectionId;
  const AData: TBytes);
begin
  // Local -> remoto. Self ja' e' a resposta para "de qual par veio isto".
  try
    FGateway.FSrv.SendBytes(FConnRemota, AData); // opaco
  except
    on E: EPipeError do
      // A remota caiu; o OnClientDisconnected do servidor ja' vai ceifar o par.
      FGateway.Log(Format('[remota %d] resposta perdida (remoto caiu?): %s',
        [FConnRemota, E.Message]));
  end;
end;

procedure TGatewayPar.LocalDisconnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  // Ponta local morreu => a remota nao tem mais servico. Derrubar COM MOTIVO e'
  // o que separa "seu certificado foi recusado" de "o servico de tras caiu".
  Derrubar('servico local encerrou a conexao');
end;

procedure TGatewayPar.LocalError(Sender: TObject; AConnId: TPipeConnectionId;
  const AError: string);
begin
  FGateway.Log(Format('[local #%d] erro: %s', [FLocalSeq, AError]));
end;

{ ----------------------------------------------------------------- gateway }

constructor TGatewaySeguro.Create(const AEnderecoTls, AEnderecoLocal: string;
  AMaxRemotos: Integer);
begin
  inherited Create;
  FEnderecoTls := AEnderecoTls;
  FEnderecoLocal := AEnderecoLocal;
  FMaxRemotos := AMaxRemotos;
  FPares := TDictionary<TPipeConnectionId, TGatewayPar>.Create;
  FParesLock := TCriticalSection.Create;
end;

destructor TGatewaySeguro.Destroy;
begin
  Parar;
  FSrv.Free;
  FCeifador.Free;
  FPares.Free;
  FParesLock.Free;
  inherited Destroy;
end;

procedure TGatewaySeguro.Log(const AMsg: string);
begin
  if Assigned(FOnLog) then
    FOnLog(Self, AMsg);
end;

procedure TGatewaySeguro.Iniciar(const APkiDir: string);
begin
  PipeAtomicSet(FParando, 0);
  FCeifador := TGatewayCeifador.Create;

  FSrv := TPipeServer.Create(FEnderecoTls, ptTls);
  // Credenciais: PKI de TESTE versionada em tests/pki (ver o LEIA-ME de la —
  // NAO tem valor de seguranca). Schannel le um PFX; OpenSSL le PEM separados.
  {$IFDEF PIPES_SCHANNEL}
  FSrv.TlsOptions.CertFile := APkiDir + 'srv.pfx';
  FSrv.TlsOptions.CertPassword := 'pipestest';
  {$ELSE}
  FSrv.TlsOptions.CertFile := APkiDir + 'srv_cert.pem';
  FSrv.TlsOptions.KeyFile := APkiDir + 'srv_key.pem';
  {$ENDIF}
  // LIGA o mTLS. E' esta linha que faz TryClientIdentity ter resposta: sem ela
  // o cliente nao apresenta certificado, nao ha identidade, e o gateway nao
  // teria o que contar ao servico local.
  FSrv.TlsOptions.CaFile := APkiDir + 'ca_cert.pem';

  // Teto de RECURSO — e aqui ele vale DOBRADO: cada conexao remota aceita abre
  // uma conexao local propria (1:1), entao N remotos custam N sockets TLS mais
  // N pipes locais, mais as threads de leitura de cada lado.
  FSrv.MaxClients := FMaxRemotos;

  // pdmSerialized nao e' detalhe: em pdmPool, OnClientConnected e o primeiro
  // OnMessage da MESMA conexao sao dois work items no pool global e podem rodar
  // fora de ordem — a mensagem chegaria antes de o par existir. Com um worker
  // so', a ordem em que a reader thread enfileirou e' a ordem em que roda
  // (ver o comentario em Pipes.Server.HandleAccepted).
  //
  // O preco: um SendBytes lento para o servico local segura o unico worker e
  // atrasa as outras conexoes remotas. Um gateway de producao trocaria isso por
  // pdmPool mais uma fila de "mensagens que chegaram antes do par".
  FSrv.DispatchMode := pdmSerialized;

  FSrv.OnClientConnected := SrvConnected;
  FSrv.OnClientDisconnected := SrvDisconnected;
  FSrv.OnMessage := SrvMessage;
  FSrv.OnError := SrvError;
  FSrv.Listen; // nao-blocante
  FAtivo := True;
end;

procedure TGatewaySeguro.SoltarTodosOsPares(AAvisar: Boolean);
var
  LPares: TArray<TGatewayPar>;
  LPar: TGatewayPar;
  I: Integer;
begin
  // Snapshot + remocao sob o lock; tudo o que fala com a lib fica FORA dele.
  SetLength(LPares, 0);
  FParesLock.Enter;
  try
    for LPar in FPares.Values do
    begin
      SetLength(LPares, Length(LPares) + 1);
      LPares[High(LPares)] := LPar;
    end;
    FPares.Clear; // a remocao E' o ato de posse
  finally
    FParesLock.Leave;
  end;
  for I := 0 to High(LPares) do
  begin
    // Marcar como "ja' em teardown" ANTES de soltar: o Disconnect que o
    // ceifador vai fazer dispara LocalDisconnected, e sem esta marca aquele
    // handler tentaria "derrubar com motivo" uma conexao remota que o Stop
    // logo abaixo ja' vai fechar — e o motivo seria o errado.
    if PipeAtomicCompareExchange(LPares[I].FCaindo, 1, 0) = 0 then
      if AAvisar then
      begin
        try
          FSrv.SendBytes(LPares[I].FConnRemota,
            GatewayRecusado('gateway encerrando'));
        except
          on E: EPipeError do
            ;
        end;
      end;
    LPares[I].Release;
  end;
end;

procedure TGatewaySeguro.Parar;
begin
  if not FAtivo then
    Exit;
  FAtivo := False;

  // 1) Fechar a porta de entrada em nivel de aplicacao: uma conexao aceita
  //    daqui em diante nao vira par nenhum (senao ela poderia se registrar
  //    DEPOIS da varredura do passo 2 e nunca ser destruida).
  PipeAtomicSet(FParando, 1);

  // 2) Soltar os pares ANTES de parar o servidor. Assim quem executa o
  //    Disconnect de cada ponta local e' o ceifador, com o servidor TLS ainda
  //    vivo para receber o RECUSADO| — e, quando o passo 4 chegar, nenhum
  //    handler de par tem mais o que tocar.
  SoltarTodosOsPares(True);

  // 3) Esperar o ceifador terminar de destruir os pares: cada destrutor faz um
  //    Disconnect SINCRONO que drena os callbacks daquele cliente local.
  FCeifador.Encerrar;

  // 4) Servidor TLS: Stop e' sincrono e drena todos os callbacks em voo.
  FSrv.Stop;

  // 5) Varredura final: um SrvConnected que tenha corrido com o passo 1 pode
  //    ter registrado um par depois do passo 2. Aqui ele nao existe mais como
  //    possibilidade — o Stop acabou de drenar os callbacks do servidor.
  SoltarTodosOsPares(False);
  FCeifador.Encerrar; // idempotente: drena o que a varredura acima enfileirou
end;

function TGatewaySeguro.AcharPar(AConnId: TPipeConnectionId): TGatewayPar;
var
  LPar: TGatewayPar;
begin
  Result := nil;
  FParesLock.Enter;
  try
    if FPares.TryGetValue(AConnId, LPar) then
    begin
      LPar.AddRef;
      Result := LPar;
    end;
  finally
    FParesLock.Leave;
  end;
end;

procedure TGatewaySeguro.Ceifar(APar: TGatewayPar);
var
  LAtual: TGatewayPar;
  LDono: Boolean;
begin
  LDono := False;
  FParesLock.Enter;
  try
    // Quem REMOVE e' quem solta a referencia do registro. Morte da remota,
    // morte da local e o Parar disputam isto; so um ganha.
    if FPares.TryGetValue(APar.FConnRemota, LAtual) and (LAtual = APar) then
    begin
      FPares.Remove(APar.FConnRemota);
      LDono := True;
    end;
  finally
    FParesLock.Leave;
  end;
  if LDono then
    APar.Release; // FORA do lock
end;

procedure TGatewaySeguro.RecusarRemoto(AConnId: TPipeConnectionId;
  const AMotivo: string);
begin
  try
    FSrv.SendBytes(AConnId, GatewayRecusado(AMotivo));
  except
    on E: EPipeError do
      ; // o remoto pode ter sumido antes de ouvir o motivo
  end;
  FSrv.DisconnectClient(AConnId); // assincrono: seguro dentro de callback
end;

function TGatewaySeguro.NomeDe(AConnId: TPipeConnectionId): string;
var
  LIdent: TPipePeerIdentity;
begin
  // A identidade SOBREVIVE a saida da conexao de proposito (ver
  // TryClientIdentity), entao da' para nomear quem saiu sem cache proprio.
  if FSrv.TryClientIdentity(AConnId, LIdent) and (LIdent.CommonName <> '') then
    Result := LIdent.CommonName
  else
    Result := '(sem identidade)';
end;

procedure TGatewaySeguro.SrvConnected(Sender: TObject;
  AConnId: TPipeConnectionId);
var
  LIdent: TPipePeerIdentity;
  LPar: TGatewayPar;
  LMotivo: string;
begin
  if PipeAtomicGet(FParando) <> 0 then
  begin
    // O gateway esta encerrando: um par criado agora poderia se registrar
    // depois da varredura do Parar e nunca ser destruido.
    RecusarRemoto(AConnId, 'gateway encerrando');
    Exit;
  end;

  // PipeTlsBackendInfo so' fica preenchido depois do PRIMEIRO handshake.
  if not FBackendLogado then
  begin
    FBackendLogado := True;
    Log('backend TLS: ' + PipeTlsBackendInfo);
  end;

  // So dispara DEPOIS do handshake mTLS completo. Com CaFile preenchido, um
  // False aqui NAO significa "espere": significa configuracao errada (mTLS nao
  // ligado). Abortar e logar alto — um gateway que repassasse sem saber quem e'
  // o par estaria mentindo no IDENT| logo a seguir.
  if not FSrv.TryClientIdentity(AConnId, LIdent) or (LIdent.CommonName = '') then
  begin
    Log(Format('!! [remota %d] estabelecida SEM identidade mTLS — CaFile nao ' +
      'esta ligado? Recusando.', [AConnId]));
    RecusarRemoto(AConnId, 'gateway sem identidade mTLS para esta conexao');
    Exit;
  end;

  LPar := TGatewayPar.Create(Self, AConnId, LIdent.CommonName);
  if not LPar.Conectar(LMotivo) then
  begin
    // DUAS CAMADAS DE "CONECTADO": o remoto autenticou com sucesso e mesmo
    // assim nao tem servico. A recusa carrega motivo por isso.
    Log(Format('[remota %d] %s autenticou, mas o servico local nao respondeu: %s',
      [AConnId, LIdent.CommonName, LMotivo]));
    RecusarRemoto(AConnId, 'servico local indisponivel: ' + LMotivo);
    // O motivo ja' foi dado: nao deixar o LocalDisconnected repetir a dose.
    PipeAtomicSet(LPar.FCaindo, 1);
    LPar.Release; // nunca registrado: vai direto para o ceifador
    Exit;
  end;

  FParesLock.Enter;
  try
    Inc(FSeqLocal);
    LPar.FLocalSeq := FSeqLocal;
    FPares.AddOrSetValue(AConnId, LPar);
  finally
    FParesLock.Leave;
  end;
  Log(Format('[remota %d] %s -> local #%d (autenticado por mTLS)',
    [AConnId, LIdent.CommonName, LPar.FLocalSeq]));
end;

procedure TGatewaySeguro.SrvMessage(Sender: TObject;
  AConnId: TPipeConnectionId; const AData: TBytes);
var
  LPar: TGatewayPar;
begin
  LPar := AcharPar(AConnId); // AddRef sob o lock
  if LPar = nil then
  begin
    Log(Format('[remota %d] mensagem sem par (ja ceifado?) — descartada',
      [AConnId]));
    Exit;
  end;
  try
    LPar.Repassar(AData); // fora do lock
  finally
    LPar.Release;
  end;
end;

procedure TGatewaySeguro.SrvDisconnected(Sender: TObject;
  AConnId: TPipeConnectionId);
var
  LPar: TGatewayPar;
begin
  Log(Format('[remota %d] %s saiu', [AConnId, NomeDe(AConnId)]));
  LPar := AcharPar(AConnId);
  if LPar = nil then
    Exit; // ja' ceifado pela outra ponta
  try
    // A remota ja' morreu: nao ha a quem mandar motivo. Marcar o par como "em
    // teardown" ANTES de ceifar impede que o LocalDisconnected — que o
    // Disconnect do ceifador vai disparar daqui a pouco — tente derrubar com
    // motivo uma conexao remota que ja' nao existe.
    PipeAtomicSet(LPar.FCaindo, 1);
    // Espelhamento de ciclo de vida: morreu a remota, morre a local.
    Ceifar(LPar);
  finally
    LPar.Release;
  end;
end;

procedure TGatewaySeguro.SrvError(Sender: TObject; AConnId: TPipeConnectionId;
  const AError: string);
begin
  // Onde cai o cliente sem certificado, de outra CA ou auto-assinado: o
  // handshake e' recusado ANTES de OnClientConnected, entao nenhum par e'
  // criado e NADA chega ao servico local. Se isso nunca aparecer contra um
  // cliente indevido, o mTLS esta decorativo.
  Log(Format('[remota %d] erro (handshake/mTLS recusado?): %s',
    [AConnId, AError]));
end;

function TGatewaySeguro.Painel: TGatewayPainel;
var
  LPar: TGatewayPar;
  I: Integer;
begin
  SetLength(Result, 0);
  FParesLock.Enter;
  try
    SetLength(Result, FPares.Count);
    I := 0;
    for LPar in FPares.Values do
    begin
      // So leitura de campos aqui dentro: nenhuma chamada a lib sob o lock.
      Result[I].ConnRemota := LPar.FConnRemota;
      Result[I].Identidade := LPar.FIdentidade;
      Result[I].LocalSeq := LPar.FLocalSeq;
      Result[I].Desde := LPar.FDesde;
      Result[I].Mensagens := PipeAtomicGet(LPar.FMensagens);
      Inc(I);
    end;
  finally
    FParesLock.Leave;
  end;
end;

end.
