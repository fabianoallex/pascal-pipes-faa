unit Pipes.Client;

{$I pipes.inc}

{ TPipeClient: cliente de Named Pipes (uma conexao).

  Threads: 1 reader (TPipeClientReaderThread) + pool de despacho (Pipes.Base)
  + 1 thread efemera de reconexao (TPipeReconnectThread, FreeOnTerminate),
  quando AutoReconnect esta ligado.

  Invariantes:
  - FWriteLock serializa as escritas E protege FStream/FEndpoint contra o
    free/troca (Disconnect e reconexao so mexem nos objetos sob o lock).
  - Disconnect e' sincrono e idempotente: encerra a reconexao em curso ->
    CloseAbort -> join do reader -> OnDisconnected -> DrainInFlight ->
    libera. NAO chamar de dentro de um callback do proprio cliente.
  - OnDisconnected dispara UMA vez por sessao (CAS em FDisconnectNotified);
    cada reconexao bem-sucedida dispara OnConnected de novo.
  - Request (sincrono) usa o padrao RPC do pascal-amqp-faa: slot com TEvent
    por corrId (FRpcSlots sob FRpcLock); a thread de leitura resolve o slot
    SOB FRpcLock (sem codigo de usuario) e o chamador, ao acordar, REMOVE o
    slot antes de le-lo — depois da remocao o reader nao o encontra mais.
    Queda da conexao falha os slots pendentes (EPipeClosed no chamador);
    reply de erro do servidor (PIPE_FLAG_ERROR) vira EPipeError.
  - Reconexao: o reader que morre dispara a thread de reconexao (CAS em
    FReconnecting garante uma so); cada tentativa e' um PipeConnect com
    timeout = ReconnectDelayMs. Disconnect/Connect/Destroy esperam a
    reconexao em curso terminar (spin em FReconnecting).
  - O espacamento entre tentativas vive no CLIENTE (FLastAttemptTick), nao na
    thread de reconexao, e e' aplicado em TryReopenSession — o funil unico por
    onde toda reabertura passa. A razao: um servidor que ACEITA e derruba em
    seguida (mTLS no Schannel valida a cadeia depois do handshake) faz cada
    ciclo terminar com a thread saindo e ReaderFinished criando uma NOVA. Um
    contador por thread reiniciaria a cada ciclo e nunca espacaria nada.
  - Pub/sub: FSubs guarda os filtros assinados como ESTADO DESEJADO do
    cliente, nao como estado da sessao. Subscribe/Unsubscribe funcionam
    desconectado e nao levantam por causa disso; o que existe em FSubs e'
    reenviado ao servidor em CADA sessao nova (Connect e cada reconexao), no
    ReplaySubscriptions, ANTES de OnConnected — assim um handler de OnConnected
    ja encontra as assinaturas restauradas em vez de precisar refaze-las.
    Sem isso, uma reconexao automatica devolveria uma conexao viva e muda: o
    servidor perdeu a lista de filtros junto com a conexao anterior (ela mora
    na conexao, ver Pipes.Server) e nao ha quem o lembre.
    O que NAO da para recuperar e' o intervalo entre a queda e o resubscribe:
    publicacao que passou ali esta perdida, e nao ha fila que a traga. Quem
    precisa do estado corrente publica com retain no servidor.
    Ordem de locks: FSubLock e' o mais interno da dupla — snapshot dos filtros
    sob ele, envio DEPOIS de solta-lo, nunca FWriteLock por dentro dele.
  - MaxReconnectAttempts vive no mesmo lugar e pela mesma razao: conta TODA
    tentativa de reabrir, e zera quando uma sessao dura mais que
    ReconnectDelayMs. Assim o teto tambem alcanca o par que aceita e derruba
    (cada ciclo dele e' uma tentativa, ainda que a conexao chegue a abrir),
    sem penalizar o cliente de longa duracao que reconecta legitimamente ao
    longo de dias. Atingido o teto, FGaveUp impede que ReaderFinished crie
    outra thread e reinicie tudo.
  - Heartbeat de aplicacao (ptTcp/ptTls; ver Pipes.Base.HeartbeatIntervalMs):
    vive por SESSAO, nao pelo cliente inteiro. StartHeartbeat roda logo apos
    CADA FReader novo (Connect e TryReopenSession); StopHeartbeat roda nos
    MESMOS pontos que ja fazem o join do FReader da sessao que esta saindo
    (Disconnect e o topo de TryReopenSession), sempre ANTES de FStream/
    FEndpoint serem trocados ou liberados — e' o que impede a heartbeat
    thread de uma sessao morta de escrever no stream da sessao seguinte.
  - Failover de endereco (FailoverAddresses): FAddrIndex e' o unico estado
    novo, e segue o mesmo dono-por-vez de FReconnectAttempts/FSessionUpTick —
    escrito so' por quem tem a sessao no momento (Connect ou a thread de
    reconexao, nunca as duas), lido de fora via PipeAtomicGet em
    GetActiveAddress. Connect SEMPRE zera FAddrIndex antes de tentar (prefere
    o primario); TryReopenSession avanca para o proximo endereco a cada
    tentativa que falha, e volta a zerar quando uma sessao e' DURAVEL (o
    mesmo criterio que zera FReconnectAttempts) — uma nova sequencia de
    falhas sempre tenta o primario primeiro, so espalhando pelos alternativos
    se ele estiver mesmo fora. MaxReconnectAttempts/ReconnectDelayMs contam e
    espacam tentativas contra QUALQUER endereco igualmente, sem orcamento
    separado por endereco. }

interface

uses
  SysUtils,
  Classes,
  SyncObjs,
  Generics.Collections,
  Pipes.Types,
  Pipes.Threading,
  Pipes.Framing,
  Pipes.Topics,
  Pipes.Transport,
  Pipes.Base;

type
  TPipeClient = class(TPipeBase)
  private
    FEndpoint: TPipeEndpoint;
    FStream: TPipeEndpointStream;
    FReader: TThread;
    FWriteLock: TCriticalSection;
    FConnected: Boolean;
    FDeliberate: Integer;         // atomico: 1 durante Disconnect deliberado
    FDisconnectNotified: Integer; // atomico: OnDisconnected ja disparado
    FOnConnected: TPipeConnectionEvent;
    FOnDisconnected: TPipeConnectionEvent;
    // --- request-reply ---
    FRpcLock: TCriticalSection;
    FRpcSlots: TDictionary<UInt64, TObject>; // corrId -> TPipeRpcSlot
    FCorrSeq: Integer;                       // atomico
    // --- reconexao ---
    FAutoReconnect: Boolean;
    FReconnectDelayMs: Cardinal;
    FMaxReconnectAttempts: Integer; // 0 = infinitas
    FReconnecting: Integer;         // atomico: 1 com thread de reconexao viva
    // Manual-reset, sinalizado pelo Disconnect: acorda na hora a espera ENTRE
    // tentativas de reconexao. Sem ele, um Sleep faria o Disconnect esperar o
    // intervalo inteiro.
    FReconnectAbort: TEvent;
    // Tick da ultima tentativa de reabrir a sessao. Vive no CLIENTE, e nao na
    // thread de reconexao, porque cada ciclo "conectou e caiu" cria uma thread
    // NOVA (ver ReaderFinished): um contador por thread nunca acumularia.
    FLastAttemptTick: UInt64; // 0 = nenhuma tentativa ainda
    // Tentativas de reabrir a sessao desde a ultima sessao DURAVEL. Vive no
    // cliente pela mesma razao de FLastAttemptTick: cada ciclo "conectou e
    // caiu" cria uma thread nova, e um contador por thread reiniciaria sempre.
    FReconnectAttempts: Integer;
    // Instante em que a sessao atual foi instalada; 0 = nenhuma.
    FSessionUpTick: UInt64;
    // --- failover de endereco ---
    // Endereco ATUAL da lista (0 = Address, 1..N = FFailoverAddresses[i-1]).
    FFailoverAddresses: TArray<string>;
    // Escrito so' por quem detem a sessao no momento (Connect OU a thread de
    // reconexao - nunca as duas ao mesmo tempo, mesma exclusao mutua de
    // FReconnecting); lido de qualquer thread via PipeAtomicGet em
    // GetActiveAddress, mesmo padrao de FReconnectAttempts em Stats.
    FAddrIndex: Integer;
    // Atomico: 1 quando MaxReconnectAttempts foi atingido. Impede que
    // ReaderFinished crie uma thread nova e ressuscite a reconexao.
    FGaveUp: Integer;
    // --- pub/sub ---
    FSubLock: TCriticalSection;
    FSubs: TList<string>;      // filtros assinados (estado desejado)
    FOnTopicMessage: TPipeTopicEvent;
    // --- heartbeat de aplicacao (ptTcp/ptTls; ver Pipes.Base.HeartbeatIntervalMs) ---
    // Vive por SESSAO: StartHeartbeat roda logo apos cada FReader novo
    // (Connect e cada TryReopenSession bem-sucedido); StopHeartbeat roda nos
    // MESMOS pontos que ja fazem o join do FReader da sessao que esta saindo
    // (Disconnect e o topo de TryReopenSession) — sempre ANTES de FStream/
    // FEndpoint serem trocados ou liberados, para a heartbeat thread nunca
    // escrever num stream de outra sessao.
    FLastReadTick: UInt64;
    FLastWriteTick: UInt64;
    FHeartbeatThread: TThread;
    FHbStopEvent: TEvent;
    // --- contadores de Stats (Pipes.Types.TPipeClientStats) ---
    // Da SESSAO atual: zeram nos MESMOS pontos que resetam FLastReadTick/
    // FLastWriteTick (Connect e cada TryReopenSession bem-sucedido). Sempre
    // ativos, sem opt-in.
    FBytesSent: UInt64;
    FBytesReceived: UInt64;
    FMessagesSent: UInt64;
    FMessagesReceived: UInt64;
    // Latencia de Request bem-sucedido (exclui timeout/erro), tambem por
    // sessao. Media = FReqTotalMs / FReqCount.
    FReqCount: UInt64;
    FReqTotalMs: UInt64;
    FReqMaxMs: UInt64;
    // Chamados pelas threads internas (mesma unit):
    procedure ReaderFinished(const AError: string);
    procedure HandleFrame(const AFrame: TPipeFrame);
    procedure StartHeartbeat;
    procedure StopHeartbeat;
    /// Zera os contadores de Stats da sessao nova. Chamada em Connect e em
    /// cada TryReopenSession bem-sucedido, SEMPRE (ao contrario de
    /// StartHeartbeat, nao depende de HeartbeatIntervalMs: os contadores de
    /// Stats sao sempre ativos).
    procedure ResetSessionStats;
    /// Atualiza FReqCount/FReqTotalMs/FReqMaxMs com um Request BEM-SUCEDIDO
    /// (chamado so' no caminho de sucesso de Request — timeout e erro nao
    /// entram na latencia, ver Stats).
    procedure RecordRequestLatency(AElapsedMs: UInt64);
    /// Callback do TPipeHeartbeatThread: manda Ping se ocioso na escrita,
    /// CloseAbort se sem NENHUM frame recebido ha' mais de 2x o intervalo.
    procedure HeartbeatTick;
    /// Reenvia todos os filtros de FSubs ao servidor. Chamada na instalacao de
    /// CADA sessao (Connect e reconexao), antes de OnConnected.
    procedure ReplaySubscriptions;
    /// Envia um frame de controle de assinatura se houver sessao; silencioso se
    /// nao houver (o replay da proxima sessao cobre).
    procedure SendControlFrame(const AFrame: TPipeFrame);
    procedure NotifyDisconnectedOnce;
    procedure ResolveRpc(const AFrame: TPipeFrame);
    procedure FailPendingRpc;
    function TryReopenSession: Boolean; // roda na thread de reconexao
    /// Completa o intervalo desde a ULTIMA tentativa de reabrir a sessao.
    /// Acorda na hora se houver Disconnect.
    procedure WaitBetweenRetries;
    procedure WaitReconnectDone;
    // --- failover de endereco ---
    function AddressCount: Integer; // 1 + Length(FFailoverAddresses)
    function AddressAt(AIndex: Integer): string; // 0 = Address; 1..N = failover
    /// Usado so' por Connect: tenta os enderecos a partir de FAddrIndex, dando
    /// voltas pela lista inteira com uma fatia igual de ATimeoutMs cada, ate
    /// um conectar ou o prazo total estourar. Com FailoverAddresses vazio e'
    /// uma unica chamada a PipeConnect(Address, ATimeoutMs, ...) - o mesmo
    /// comportamento de antes desta feature. Atualiza FAddrIndex para o
    /// endereco que conectou.
    function ConnectAnyAddress(ATimeoutMs: Cardinal): TPipeEndpoint;
    function GetActiveAddress: string;
  protected
    function GetActive: Boolean; override;
  public
    constructor Create(const AAddress: string;
      ATransport: TPipeTransport = ptLocal);
    destructor Destroy; override;
    /// Conecta (re-tentando ate ATimeoutMs; EPipeTimeout no prazo). Se havia
    /// uma sessao anterior (viva ou morta), e' encerrada antes.
    procedure Connect(ATimeoutMs: Cardinal = 5000);
    /// Sincrono e idempotente.
    procedure Disconnect;
    procedure SendBytes(const AData: TBytes);
    procedure SendText(const AText: string);
    /// Request-reply sincrono: bloqueia o CHAMADOR (nunca a thread de
    /// leitura) ate o reply, EPipeTimeout no prazo, EPipeError se o servidor
    /// respondeu com erro (excecao no OnRequest ou handler ausente),
    /// EPipeClosed se a conexao caiu no meio.
    function Request(const AData: TBytes; ATimeoutMs: Cardinal = 30000): TBytes;
    function RequestText(const AText: string; ATimeoutMs: Cardinal = 30000): string;
    /// Snapshot da SESSAO atual (zera a cada Connect/reconexao) — sem
    /// contador cumulativo entre sessoes de proposito, ver TPipeClientStats.
    function Stats: TPipeClientStats;
    // --- pub/sub ---------------------------------------------------------
    /// Passa a receber, em OnTopicMessage, as publicacoes que AFilter alcanca.
    /// O filtro e' hierarquico e aceita curingas: 'caixa.3.status',
    /// 'caixa.*.status' (um segmento), 'caixa.#' (o resto). EPipeError se o
    /// filtro for invalido — erro de programacao, aparece na hora.
    ///
    /// Funciona DESCONECTADO: registra a intencao e a aplica quando houver
    /// sessao. E' reaplicada a cada reconexao automatica, sem o app precisar
    /// refazer nada no OnConnected. Assinar duas vezes o mesmo filtro nao muda
    /// nada (nem duplica entrega).
    ///
    /// Nao ha confirmacao a esperar: se o servidor recusar (filtro invalido ou
    /// teto de assinaturas), a recusa chega em OnError, nao aqui.
    procedure Subscribe(const AFilter: string);
    /// Deixa de receber o que AFilter alcanca. Silencioso se nao estava
    /// assinado; tambem funciona desconectado.
    procedure Unsubscribe(const AFilter: string);
    /// Filtros atualmente assinados (o estado desejado, nao o confirmado).
    function Subscriptions: TArray<string>;
    /// Publica em ATopic. Nome literal, sem curinga; EPipeError se invalido,
    /// EPipeClosed se nao ha sessao (diferente de Subscribe: publicar e' um
    /// acontecimento com hora, nao uma intencao que se guarda para depois).
    ///
    /// Quem recebe depende do servidor: com RelayClientPublish ligado, os
    /// outros assinantes daquele topico; desligado (o padrao), so' o proprio
    /// servidor, em OnPublish.
    procedure Publish(const ATopic: string; const AData: TBytes);
    procedure PublishText(const ATopic, AText: string);
    /// Chegou uma publicacao que casa com algum filtro assinado. AConnId e' 0
    /// (o cliente tem uma conexao so').
    ///
    /// ARetained = True significa "isto nao aconteceu agora": e' o valor que o
    /// servidor guardava do topico, entregue porque a assinatura acabou de ser
    /// feita. Publicacao ao vivo chega sempre False — inclusive quando o
    /// publicador pediu retencao. Use para nao tratar catch-up como evento
    /// (nao toque a campainha, nao conte como venda, so' pinte o estado).
    property OnTopicMessage: TPipeTopicEvent
      read FOnTopicMessage write FOnTopicMessage;
    property Connected: Boolean read GetActive;
    property AutoReconnect: Boolean read FAutoReconnect write FAutoReconnect;
    property ReconnectDelayMs: Cardinal read FReconnectDelayMs write FReconnectDelayMs;
    property MaxReconnectAttempts: Integer
      read FMaxReconnectAttempts write FMaxReconnectAttempts;
    /// Enderecos alternativos, tentados em ordem DEPOIS de Address (o
    /// primario) quando ele falha - em Connect e em cada tentativa de
    /// reconexao automatica. Mesmo Transport/TlsOptions/KeepAliveSeconds do
    /// cliente: sao enderecos de rede alternativos do MESMO servico, nao
    /// servidores com protocolo/credenciais diferentes. Vazio (o padrao) =
    /// comportamento de sempre, so' Address. Definir antes do primeiro
    /// Connect, como AutoReconnect - nao e' pensado para mudar com uma
    /// reconexao em curso.
    property FailoverAddresses: TArray<string>
      read FFailoverAddresses write FFailoverAddresses;
    /// Qual endereco a sessao ATUAL (ou a ultima tentada) realmente usa -
    /// Address ou um item de FailoverAddresses. Snapshot, mesmo molde de
    /// ClientCount/Subscriptions.
    property ActiveAddress: string read GetActiveAddress;
    property OnConnected: TPipeConnectionEvent
      read FOnConnected write FOnConnected;
    property OnDisconnected: TPipeConnectionEvent
      read FOnDisconnected write FOnDisconnected;
  end;

  /// Alias de compatibilidade (ver TNamedPipeBase em Pipes.Base).
  TNamedPipeClient = TPipeClient;

implementation

type
  { Slot de um Request pendente. Posse: o CHAMADOR cria, registra, remove e
    libera; o reader so preenche/sinaliza enquanto o slot esta no dicionario
    (sempre sob FRpcLock). }
  TPipeRpcSlot = class
  public
    Event: TEvent; // manual-reset
    Data: TBytes;
    Ok: Boolean;
    IsError: Boolean;  // reply com PIPE_FLAG_ERROR
    ErrorMsg: string;
    Closed: Boolean;   // conexao caiu antes do reply
    constructor Create;
    destructor Destroy; override;
  end;

  TPipeClientReaderThread = class(TThread)
  private
    FClient: TPipeClient;
  protected
    procedure Execute; override;
  public
    constructor Create(AClient: TPipeClient);
  end;

  { Thread efemera de reconexao (padrao TAMQPReconnectThread). }
  TPipeReconnectThread = class(TThread)
  private
    FClient: TPipeClient;
  protected
    procedure Execute; override;
  public
    constructor Create(AClient: TPipeClient);
  end;

{ TPipeRpcSlot }

constructor TPipeRpcSlot.Create;
begin
  inherited Create;
  Event := TEvent.Create(nil, True, False, '');
end;

destructor TPipeRpcSlot.Destroy;
begin
  Event.Free;
  inherited;
end;

{ TPipeClientReaderThread }

constructor TPipeClientReaderThread.Create(AClient: TPipeClient);
begin
  FClient := AClient;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TPipeClientReaderThread.Execute;
var
  LFrame: TPipeFrame;
begin
  try
    while True do
    begin
      LFrame := PipeReadFrame(FClient.FStream, FClient.MaxMessageSize);
      PipeAtomicWrite64(FClient.FLastReadTick, PipeTickMs);
      PipeAtomicAdd64(FClient.FBytesReceived,
        PIPE_FRAME_HEADER_SIZE + UInt64(Length(LFrame.Payload)));
      PipeAtomicAdd64(FClient.FMessagesReceived, 1);
      FClient.HandleFrame(LFrame);
    end;
  except
    on EPipeClosed do
      FClient.ReaderFinished(''); // servidor encerrou ou Disconnect local
    on E: Exception do
      FClient.ReaderFinished(E.Message);
  end;
end;

{ TPipeReconnectThread }

constructor TPipeReconnectThread.Create(AClient: TPipeClient);
begin
  FClient := AClient;
  FreeOnTerminate := True; // se auto-libera; quem sincroniza e' FReconnecting
  inherited Create(False);
end;

procedure TPipeReconnectThread.Execute;
var
  LDePe: Boolean;
begin
  // O contador de tentativas e o teto vivem em TryReopenSession, no cliente:
  // aqui eles reiniciariam a cada thread nova (ver ReaderFinished).
  while (PipeAtomicGet(FClient.FDeliberate) = 0) and
        (PipeAtomicGet(FClient.FGaveUp) = 0) do
  begin
    LDePe := False;
    if FClient.TryReopenSession then
    begin
      // TryReopenSession zera FReconnecting DEPOIS de a sessao estar completa
      // (reader criado). Se a sessao nova ja caiu neste intervalo, o CAS
      // retoma o loop — sem ele a queda instantanea perderia a reconexao.
      //
      // "Conectou e caiu no mesmo instante" NAO e' sucesso, e conta como
      // tentativa. O caso real e' o servidor mTLS no backend SChannel: ele
      // completa o handshake e SO ENTAO valida a cadeia, entao um cliente com
      // certificado recusado ve conexao estabelecida seguida de queda
      // imediata. Tratar isso como sucesso fazia o laco girar sem espacamento
      // e sem nunca alcancar MaxReconnectAttempts — martelando o servidor
      // dezenas de vezes por segundo com uma credencial que ele acabou de
      // rejeitar.
      LDePe := not ((PipeAtomicGet(FClient.FDeliberate) = 0) and
                    (not FClient.FConnected) and
                    (PipeAtomicCompareExchange(FClient.FReconnecting, 1, 0) = 0));
      if LDePe then
        Exit; // reconectou e a sessao continua de pe
    end;
  end;
  PipeAtomicSet(FClient.FReconnecting, 0); // desistiu (deliberado ou esgotado)
end;

{ TPipeClient }

constructor TPipeClient.Create(const AAddress: string;
  ATransport: TPipeTransport);
begin
  inherited Create(AAddress, ATransport);
  FWriteLock := TCriticalSection.Create;
  FRpcLock := TCriticalSection.Create;
  FRpcSlots := TDictionary<UInt64, TObject>.Create;
  FSubLock := TCriticalSection.Create;
  FSubs := TList<string>.Create;
  FReconnectAbort := TEvent.Create(nil, True, False, ''); // manual-reset
  FReconnectDelayMs := 2000;
end;

destructor TPipeClient.Destroy;
begin
  try
    Disconnect; // idempotente
  except
  end;
  FRpcSlots.Free; // vazio: cada Request remove e libera o proprio slot
  FRpcLock.Free;
  FWriteLock.Free;
  FSubs.Free;
  FSubLock.Free;
  FReconnectAbort.Free;
  inherited;
end;

function TPipeClient.GetActive: Boolean;
begin
  Result := FConnected;
end;

procedure TPipeClient.WaitBetweenRetries;
var
  LRestante: Int64;
begin
  if FLastAttemptTick = 0 then
    Exit; // primeira tentativa desta reconexao: vai direto
  LRestante := Int64(FReconnectDelayMs) -
    (Int64(PipeTickMs) - Int64(FLastAttemptTick));
  if LRestante <= 0 then
    Exit; // a propria tentativa ja consumiu o intervalo
  // Espera no evento, nao em Sleep: um Disconnect durante o intervalo acorda
  // aqui na hora, em vez de deixar o usuario esperando o ciclo terminar.
  FReconnectAbort.WaitFor(Cardinal(LRestante));
end;

procedure TPipeClient.WaitReconnectDone;
begin
  // FDeliberate ja esta em 1: a thread de reconexao desiste no proximo passo
  // (pior caso: espera um PipeConnect de ate ReconnectDelayMs terminar).
  while PipeAtomicGet(FReconnecting) <> 0 do
    Sleep(5);
end;

function TPipeClient.AddressCount: Integer;
begin
  Result := 1 + Length(FFailoverAddresses);
end;

function TPipeClient.AddressAt(AIndex: Integer): string;
begin
  if AIndex <= 0 then
    Result := Address
  else
    Result := FFailoverAddresses[AIndex - 1];
end;

function TPipeClient.GetActiveAddress: string;
begin
  Result := AddressAt(PipeAtomicGet(FAddrIndex));
end;

function TPipeClient.ConnectAnyAddress(ATimeoutMs: Cardinal): TPipeEndpoint;
var
  LCount, LSliceMs: Integer;
  LDeadline: UInt64;
  LLastErr: string;
  LLastWasTimeout: Boolean;
begin
  LCount := AddressCount;
  if LCount = 1 then
    // Sem FailoverAddresses: uma unica chamada, comportamento identico ao de
    // antes desta feature (nenhuma volta extra, orcamento inteiro pro unico
    // endereco).
    Exit(PipeConnect(Address, ATimeoutMs, Transport, KeepAliveSeconds,
      TlsOptions.AsOptions));

  LSliceMs := ATimeoutMs div Cardinal(LCount);
  if LSliceMs = 0 then
    LSliceMs := 1;
  LDeadline := PipeTickMs + ATimeoutMs;
  LLastErr := '';
  LLastWasTimeout := True;
  repeat
    try
      Result := PipeConnect(AddressAt(FAddrIndex), LSliceMs, Transport,
        KeepAliveSeconds, TlsOptions.AsOptions);
      Exit; // FAddrIndex ja aponta pro endereco que funcionou
    except
      on E: EPipeError do
      begin
        LLastErr := E.Message;
        LLastWasTimeout := E is EPipeTimeout;
        FAddrIndex := (FAddrIndex + 1) mod LCount;
      end;
    end;
  until PipeTickMs >= LDeadline;
  if LLastWasTimeout then
    raise EPipeTimeout.CreateFmt(
      'nenhum dos %d enderecos respondeu em %u ms (ultimo erro: %s)',
      [LCount, ATimeoutMs, LLastErr])
  else
    raise EPipeError.CreateFmt('nenhum dos %d enderecos conectou (ultimo erro: %s)',
      [LCount, LLastErr]);
end;

procedure TPipeClient.Connect(ATimeoutMs: Cardinal);
begin
  Disconnect; // encerra/limpa sessao anterior (viva ou morta); idempotente
  SetupDispatch;
  FAddrIndex := 0; // Connect explicito sempre prefere o primario (Address)
  try
    FEndpoint := ConnectAnyAddress(ATimeoutMs);
  except
    TeardownDispatch;
    raise;
  end;
  FStream := TPipeEndpointStream.Create(FEndpoint);
  FReconnectAbort.ResetEvent; // sessao nova: o abort anterior nao vale mais
  FLastAttemptTick := 0;      // Connect explicito nao espera espacamento
  FReconnectAttempts := 0;    // e reabre o orcamento de tentativas
  FSessionUpTick := PipeTickMs;
  PipeAtomicSet(FGaveUp, 0);
  PipeAtomicSet(FDeliberate, 0);
  PipeAtomicSet(FDisconnectNotified, 0);
  FConnected := True;
  FReader := TPipeClientReaderThread.Create(Self);
  ResetSessionStats;
  StartHeartbeat;
  // Antes de OnConnected: quem assinou algo antes do Connect encontra as
  // assinaturas ja enviadas quando o proprio handler rodar.
  ReplaySubscriptions;
  DispatchConnEvent(FOnConnected, 0);
end;

procedure TPipeClient.Disconnect;
var
  LHadSession: Boolean;
begin
  PipeAtomicSet(FDeliberate, 1);
  // Antes do WaitReconnectDone: se a thread de reconexao estiver no intervalo
  // entre tentativas, isto a acorda em vez de deixar o Disconnect esperando.
  FReconnectAbort.SetEvent;
  WaitReconnectDone; // depois disto, so esta thread mexe na sessao
  LHadSession := Assigned(FEndpoint);
  FConnected := False;
  if LHadSession then
    FEndpoint.CloseAbort; // desbloqueia o reader (e escritas em andamento)
  if Assigned(FReader) then
  begin
    FReader.WaitFor;
    FreeAndNil(FReader);
  end;
  StopHeartbeat;
  FailPendingRpc; // acorda Requests pendentes com EPipeClosed
  if LHadSession then
    NotifyDisconnectedOnce;
  DrainInFlight;
  TeardownDispatch;
  // Sob o write lock: um SendBytes/Request concorrente ou termina antes ou
  // ja ve FConnected=False; nunca escreve num stream liberado.
  FWriteLock.Enter;
  try
    FreeAndNil(FStream);
    FreeAndNil(FEndpoint);
  finally
    FWriteLock.Leave;
  end;
end;

function TPipeClient.TryReopenSession: Boolean;
var
  LEndpoint: TPipeEndpoint;
begin
  Result := False;
  if PipeAtomicGet(FDeliberate) <> 0 then
    Exit;
  // Limpa a sessao morta (o reader que disparou a reconexao ja esta saindo).
  if Assigned(FReader) then
  begin
    FReader.WaitFor;
    FreeAndNil(FReader);
  end;
  StopHeartbeat; // ANTES de liberar FStream/FEndpoint da sessao morta
  FWriteLock.Enter;
  try
    FreeAndNil(FStream);
    FreeAndNil(FEndpoint);
  finally
    FWriteLock.Leave;
  end;
  // Espacamento ANTES de cada tentativa, e nao depois: este e' o funil unico
  // por onde toda reabertura passa, venha ela do laco da thread de reconexao
  // ou de uma thread NOVA criada por ReaderFinished.
  //
  // PipeConnect ja consome ate ReconnectDelayMs quando o servidor esta fora do
  // ar, mas quando ele responde e RECUSA a tentativa volta em milissegundos —
  // e era esse o caso do servidor mTLS no SChannel, que aceita o handshake e
  // so' depois valida a cadeia.
  WaitBetweenRetries;
  if PipeAtomicGet(FDeliberate) <> 0 then
    Exit; // Disconnect durante a espera
  // AutoReconnect e' relido AQUI, e nao so' quando a thread foi criada. Sem
  // isto, desliga-lo de dentro de OnDisconnected nao teria efeito sobre a
  // tentativa ja em curso: em pdmMainThread o evento e' ENFILEIRADO para a
  // thread da UI, entao ReaderFinished ja decidiu reconectar antes de o
  // handler do usuario rodar. Reler no ultimo instante possivel torna
  // "AutoReconnect := False" util de dentro do proprio callback.
  if not FAutoReconnect then
    Exit;

  // Uma sessao que durou MAIS que o intervalo entre tentativas foi uma sessao
  // de verdade, e nao um "aceita e derruba": zera o contador. O criterio se
  // ancora em ReconnectDelayMs em vez de uma constante magica — se o usuario
  // considera 2s um espacamento razoavel entre tentativas, uma sessao que
  // passou disso produziu trabalho util.
  //
  // Sem isso, um cliente de longa duracao que reconecta legitimamente varias
  // vezes ao longo de dias acabaria esbarrando no teto.
  if (FSessionUpTick <> 0) and
     (Int64(PipeTickMs) - Int64(FSessionUpTick) >= Int64(FReconnectDelayMs)) then
  begin
    FReconnectAttempts := 0;
    // Sessao duravel: a proxima FALHA (se houver) volta a preferir o
    // primario, em vez de continuar de onde a volta pela lista havia parado.
    FAddrIndex := 0;
  end;
  FSessionUpTick := 0;

  Inc(FReconnectAttempts);
  if (FMaxReconnectAttempts > 0) and
     (FReconnectAttempts > FMaxReconnectAttempts) then
  begin
    // FGaveUp e' o que impede ReaderFinished de criar outra thread e reiniciar
    // tudo. Sem ele o teto so' valeria dentro de uma thread, que e' justamente
    // o furo que fazia o par "aceita e derruba" nunca esbarrar no limite.
    PipeAtomicSet(FGaveUp, 1);
    DispatchError(0, 'reconexao esgotada apos ' +
      IntToStr(FMaxReconnectAttempts) + ' tentativas');
    Exit;
  end;
  FLastAttemptTick := PipeTickMs;
  try
    // Reconexao usa as MESMAS credenciais: um cliente que reconecta sem elas
    // voltaria em texto claro, ou seria recusado pelo servidor mTLS.
    LEndpoint := PipeConnect(AddressAt(FAddrIndex), FReconnectDelayMs, Transport,
      KeepAliveSeconds, TlsOptions.AsOptions);
  except
    on EPipeError do
    begin
      // Endereco atual falhou: a PROXIMA tentativa mira o seguinte da lista
      // (com FailoverAddresses vazio, AddressCount = 1 e isto e' sempre 0).
      FAddrIndex := (FAddrIndex + 1) mod AddressCount;
      Exit; // inclui EPipeTimeout: proxima tentativa (ou desiste no teto)
    end;
  end;
  // Segunda checagem, agora com a conexao ja aberta: a flag pode ter virado
  // DURANTE o PipeConnect. Descartar aqui e' o que impede uma sessao natimorta
  // de ser instalada e anunciada com OnConnected — o usuario veria "conectado"
  // depois de ja ter decidido parar de reconectar, que foi exatamente o
  // sintoma observado no sample apos a recusa de certificado.
  //
  // Nao fecha a janela por completo (nada fecha: o par pode aceitar no exato
  // instante da decisao), mas reduz a um caso raro o que antes era certo.
  if (PipeAtomicGet(FDeliberate) <> 0) or (not FAutoReconnect) then
  begin
    LEndpoint.CloseAbort;
    LEndpoint.Free;
    Exit;
  end;
  FWriteLock.Enter;
  try
    FEndpoint := LEndpoint;
    FStream := TPipeEndpointStream.Create(LEndpoint);
  finally
    FWriteLock.Leave;
  end;
  PipeAtomicSet(FDisconnectNotified, 0);
  FConnected := True;
  FSessionUpTick := PipeTickMs; // marca para o criterio de sessao duravel
  FReader := TPipeClientReaderThread.Create(Self);
  ResetSessionStats;
  StartHeartbeat;
  // A conexao anterior levou consigo a lista de filtros do lado do servidor:
  // sem este replay a sessao nova voltaria viva e muda, e o sintoma (mensagens
  // que param de chegar depois de uma reconexao que o app nem viu) seria
  // atribuido a qualquer coisa menos a isto.
  ReplaySubscriptions;
  DispatchConnEvent(FOnConnected, 0);
  // So DEPOIS de a sessao estar completa (FReader atribuido): e' este flag
  // que libera o WaitReconnectDone do Disconnect — zera-lo antes deixaria o
  // Disconnect correr em paralelo com a montagem da sessao.
  PipeAtomicSet(FReconnecting, 0);
  Result := True;
end;

procedure TPipeClient.NotifyDisconnectedOnce;
begin
  if PipeAtomicCompareExchange(FDisconnectNotified, 1, 0) = 0 then
    DispatchConnEvent(FOnDisconnected, 0);
end;

procedure TPipeClient.ResetSessionStats;
begin
  PipeAtomicWrite64(FBytesSent, 0);
  PipeAtomicWrite64(FBytesReceived, 0);
  PipeAtomicWrite64(FMessagesSent, 0);
  PipeAtomicWrite64(FMessagesReceived, 0);
  PipeAtomicWrite64(FReqCount, 0);
  PipeAtomicWrite64(FReqTotalMs, 0);
  PipeAtomicWrite64(FReqMaxMs, 0);
end;

procedure TPipeClient.RecordRequestLatency(AElapsedMs: UInt64);
var
  LOldMax: UInt64;
begin
  PipeAtomicAdd64(FReqCount, 1);
  PipeAtomicAdd64(FReqTotalMs, AElapsedMs);
  // CAS loop para o maximo: um Add64 simples nao serve (nao e' soma, e' "so
  // atualiza se for maior"), e duas chamadas concorrentes de Request podem
  // disputar o mesmo campo.
  repeat
    LOldMax := PipeAtomicRead64(FReqMaxMs);
    if AElapsedMs <= LOldMax then
      Break;
  until PipeAtomicCompareExchange64(FReqMaxMs, AElapsedMs, LOldMax) = LOldMax;
end;

procedure TPipeClient.StartHeartbeat;
begin
  if (HeartbeatIntervalMs = 0) or not (Transport in [ptTcp, ptTls]) then
    Exit;
  PipeAtomicWrite64(FLastReadTick, PipeTickMs);
  PipeAtomicWrite64(FLastWriteTick, PipeTickMs);
  FHbStopEvent := TEvent.Create(nil, True, False, ''); // manual-reset
  FHeartbeatThread := TPipeHeartbeatThread.Create(HeartbeatIntervalMs,
    FHbStopEvent, HeartbeatTick);
end;

procedure TPipeClient.StopHeartbeat;
begin
  if not Assigned(FHeartbeatThread) then
    Exit;
  FHeartbeatThread.Terminate;
  FHbStopEvent.SetEvent;
  FHeartbeatThread.WaitFor;
  FreeAndNil(FHeartbeatThread);
  FreeAndNil(FHbStopEvent);
end;

procedure TPipeClient.HeartbeatTick;
var
  LNow: UInt64;
begin
  LNow := PipeTickMs;
  // Nenhum frame recebido (Ping incluso) ha' mais de 2x o intervalo: trata
  // como morta. CloseAbort e' thread-safe/idempotente (Pipes.Transport) e
  // desbloqueia a propria reader thread, que segue o teardown normal
  // (ReaderFinished, e AutoReconnect se estiver ligado).
  if (LNow - PipeAtomicRead64(FLastReadTick)) >
     (2 * UInt64(HeartbeatIntervalMs)) then
  begin
    if FConnected and Assigned(FEndpoint) then
      FEndpoint.CloseAbort;
    Exit;
  end;
  // Ocioso na escrita ha' >= metade do intervalo: manda um Ping para o
  // servidor resetar o relogio de leitura dele.
  if (LNow - PipeAtomicRead64(FLastWriteTick)) <
     (UInt64(HeartbeatIntervalMs) div 2) then
    Exit;
  FWriteLock.Enter;
  try
    if (not FConnected) or (FStream = nil) then
      Exit; // sessao trocou/caiu entre a checagem acima e aqui
    try
      PipeWriteFrame(FStream, TPipeFrame.Ping, MaxMessageSize);
      PipeAtomicWrite64(FLastWriteTick, PipeTickMs);
      PipeAtomicAdd64(FBytesSent, PIPE_FRAME_HEADER_SIZE);
      PipeAtomicAdd64(FMessagesSent, 1);
    except
      // Escrita falhou = sessao morrendo (mesma tolerancia de
      // SendControlFrame): o reader esta a ponto de notificar a queda.
    end;
  finally
    FWriteLock.Leave;
  end;
end;

procedure TPipeClient.ReaderFinished(const AError: string);
begin
  FConnected := False;
  FailPendingRpc; // Requests pendentes acordam com EPipeClosed
  if PipeAtomicGet(FDeliberate) <> 0 then
    Exit; // Disconnect deliberado: quem notifica e' o proprio Disconnect
  if AError <> '' then
    DispatchError(0, AError);
  NotifyDisconnectedOnce;
  if FAutoReconnect and (PipeAtomicGet(FGaveUp) = 0) and
     (PipeAtomicCompareExchange(FReconnecting, 1, 0) = 0) then
    TPipeReconnectThread.Create(Self);
end;

procedure TPipeClient.HandleFrame(const AFrame: TPipeFrame);
var
  LTopic: string;
  LBody: TBytes;
begin
  case AFrame.Kind of
    pfkMessage:
      DispatchMessage(0, AFrame.Payload);
    pfkReply:
      // corrId 0 nunca pertence a um Request (a sequencia comeca em 1): e' uma
      // recusa assincrona do servidor — assinatura invalida, teto de
      // assinaturas — e o unico lugar sensato para ela e' OnError.
      if (AFrame.CorrId = 0) and AFrame.IsError then
        DispatchError(0, AFrame.PayloadAsText)
      else
        ResolveRpc(AFrame); // sob FRpcLock, sem codigo de usuario: roda aqui
    pfkPublish:
      begin
        // Decodificar e' codigo puro; o handler do usuario vai para o pool como
        // qualquer outro evento.
        PipeDecodeTopicPayload(AFrame.Payload, LTopic, LBody);
        // IsRetain aqui responde "isto e' historico?": so' o catch-up de
        // assinatura liga esse bit (ver TPipeServer.FanOut).
        DispatchTopicEvent(FOnTopicMessage, 0, LTopic, LBody, AFrame.IsRetain);
      end;
    pfkPing, pfkRequest, pfkSubscribe, pfkUnsubscribe:
      ; // ping: reservado; os demais nao existem no sentido servidor -> cliente
  end;
end;

{ Busca explicita, em vez de TList<string>.IndexOf: o comparador default de
  string nao tem a mesma sensibilidade a caixa nos dois compiladores, e topico e'
  comparado byte a byte (ver Pipes.Topics). Gemea da de Pipes.Server. }
function IndexOfFilter(AList: TList<string>; const AFilter: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to AList.Count - 1 do
    if AList[I] = AFilter then
      Exit(I);
end;

procedure TPipeClient.SendControlFrame(const AFrame: TPipeFrame);
begin
  FWriteLock.Enter;
  try
    if (not FConnected) or (FStream = nil) then
      Exit; // sem sessao: o replay da proxima cobre
    try
      PipeWriteFrame(FStream, AFrame, MaxMessageSize);
      PipeAtomicWrite64(FLastWriteTick, PipeTickMs);
      PipeAtomicAdd64(FBytesSent,
        PIPE_FRAME_HEADER_SIZE + UInt64(Length(AFrame.Payload)));
      PipeAtomicAdd64(FMessagesSent, 1);
    except
      // Escrita falhou = sessao morrendo. Nao levanta: o reader esta a ponto de
      // notificar a queda, e o filtro (que ja esta em FSubs) volta no replay da
      // proxima sessao. Levantar aqui obrigaria todo Subscribe a um try/except
      // que nao teria nada de util a fazer.
    end;
  finally
    FWriteLock.Leave; // no finally: o Exit acima tambem passa por aqui
  end;
end;

procedure TPipeClient.ReplaySubscriptions;
var
  LFilters: TArray<string>;
  I: Integer;
begin
  // Snapshot sob FSubLock e envio DEPOIS de solta-lo: FSubLock nunca contem
  // FWriteLock por dentro (ver o cabecalho da unit).
  FSubLock.Enter;
  try
    SetLength(LFilters, FSubs.Count);
    for I := 0 to FSubs.Count - 1 do
      LFilters[I] := FSubs[I];
  finally
    FSubLock.Leave;
  end;
  for I := 0 to High(LFilters) do
    SendControlFrame(PipeSubscribeFrame(LFilters[I]));
end;

procedure TPipeClient.Subscribe(const AFilter: string);
var
  LNovo: Boolean;
begin
  if not PipeIsValidTopicFilter(AFilter) then
    raise EPipeError.CreateFmt('filtro de assinatura invalido: %s', [AFilter]);
  FSubLock.Enter;
  try
    LNovo := IndexOfFilter(FSubs, AFilter) < 0;
    if LNovo then
      FSubs.Add(AFilter);
  finally
    FSubLock.Leave;
  end;
  if LNovo then
    SendControlFrame(PipeSubscribeFrame(AFilter));
end;

procedure TPipeClient.Unsubscribe(const AFilter: string);
var
  LIdx: Integer;
begin
  FSubLock.Enter;
  try
    LIdx := IndexOfFilter(FSubs, AFilter);
    if LIdx >= 0 then
      FSubs.Delete(LIdx);
  finally
    FSubLock.Leave;
  end;
  if LIdx >= 0 then
    SendControlFrame(PipeUnsubscribeFrame(AFilter));
end;

function TPipeClient.Subscriptions: TArray<string>;
var
  I: Integer;
begin
  Result := nil; // silencia o aviso do FPC sobre Result gerenciado nao iniciado
  FSubLock.Enter;
  try
    SetLength(Result, FSubs.Count);
    for I := 0 to FSubs.Count - 1 do
      Result[I] := FSubs[I];
  finally
    FSubLock.Leave;
  end;
end;

procedure TPipeClient.Publish(const ATopic: string; const AData: TBytes);
var
  LFrame: TPipeFrame;
begin
  if not PipeIsValidTopic(ATopic) then
    raise EPipeError.CreateFmt('topico invalido para publicacao: %s', [ATopic]);
  FWriteLock.Enter;
  try
    if (not FConnected) or (FStream = nil) then
      raise EPipeClosed.Create('cliente nao esta conectado');
    LFrame := PipePublishFrame(ATopic, AData, False);
    PipeWriteFrame(FStream, LFrame, MaxMessageSize);
    PipeAtomicWrite64(FLastWriteTick, PipeTickMs);
    // Tamanho do payload JA CODIFICADO (topico em UTF-8 + envelope), nao um
    // recalculo manual: Length(ATopic) sozinho mentiria para topico nao-ASCII.
    PipeAtomicAdd64(FBytesSent,
      PIPE_FRAME_HEADER_SIZE + UInt64(Length(LFrame.Payload)));
    PipeAtomicAdd64(FMessagesSent, 1);
  finally
    FWriteLock.Leave;
  end;
end;

procedure TPipeClient.PublishText(const ATopic, AText: string);
begin
  Publish(ATopic, PipeUtf8Encode(AText));
end;

procedure TPipeClient.ResolveRpc(const AFrame: TPipeFrame);
var
  LObj: TObject;
  LSlot: TPipeRpcSlot;
begin
  FRpcLock.Enter;
  try
    if not FRpcSlots.TryGetValue(AFrame.CorrId, LObj) then
      Exit; // reply tardio de um Request que ja desistiu (timeout): descarta
    LSlot := TPipeRpcSlot(LObj);
    if AFrame.IsError then
    begin
      LSlot.IsError := True;
      LSlot.ErrorMsg := AFrame.PayloadAsText;
    end
    else
    begin
      LSlot.Data := AFrame.Payload;
      LSlot.Ok := True;
    end;
    LSlot.Event.SetEvent;
  finally
    FRpcLock.Leave;
  end;
end;

procedure TPipeClient.FailPendingRpc;
var
  LObj: TObject;
begin
  FRpcLock.Enter;
  try
    for LObj in FRpcSlots.Values do
    begin
      TPipeRpcSlot(LObj).Closed := True;
      TPipeRpcSlot(LObj).Event.SetEvent;
    end;
  finally
    FRpcLock.Leave;
  end;
end;

function TPipeClient.Request(const AData: TBytes;
  ATimeoutMs: Cardinal): TBytes;
var
  LCorrId: UInt64;
  LSlot: TPipeRpcSlot;
  LStart: UInt64;
begin
  LStart := PipeTickMs;
  LCorrId := UInt64(Cardinal(PipeAtomicInc(FCorrSeq)));
  LSlot := TPipeRpcSlot.Create;
  try
    FRpcLock.Enter;
    try
      FRpcSlots.Add(LCorrId, LSlot);
    finally
      FRpcLock.Leave;
    end;
    try
      FWriteLock.Enter;
      try
        if (not FConnected) or (FStream = nil) then
          raise EPipeClosed.Create('cliente nao esta conectado');
        PipeWriteFrame(FStream, TPipeFrame.Request(LCorrId, AData), MaxMessageSize);
        PipeAtomicWrite64(FLastWriteTick, PipeTickMs);
        PipeAtomicAdd64(FBytesSent, PIPE_FRAME_HEADER_SIZE + UInt64(Length(AData)));
        PipeAtomicAdd64(FMessagesSent, 1);
      finally
        FWriteLock.Leave;
      end;
    except
      FRpcLock.Enter;
      try
        FRpcSlots.Remove(LCorrId);
      finally
        FRpcLock.Leave;
      end;
      raise;
    end;
    LSlot.Event.WaitFor(ATimeoutMs);
    // Remove ANTES de ler: depois disto o reader nao encontra mais o slot.
    FRpcLock.Enter;
    try
      FRpcSlots.Remove(LCorrId);
    finally
      FRpcLock.Leave;
    end;
    if LSlot.IsError then
      raise EPipeError.Create('servidor respondeu erro: ' + LSlot.ErrorMsg);
    if LSlot.Ok then
    begin
      // So' o caminho de sucesso entra na latencia — timeout e erro nao sao
      // "quanto tempo o servidor levou para responder".
      RecordRequestLatency(PipeTickMs - LStart);
      Exit(LSlot.Data); // inclui reply que chegou entre o timeout e a remocao
    end;
    if LSlot.Closed then
      raise EPipeClosed.Create('conexao encerrada durante o request');
    raise EPipeTimeout.CreateFmt('request sem resposta em %u ms', [ATimeoutMs]);
  finally
    LSlot.Free;
  end;
end;

function TPipeClient.RequestText(const AText: string;
  ATimeoutMs: Cardinal): string;
begin
  Result := PipeUtf8Decode(Request(PipeUtf8Encode(AText), ATimeoutMs));
end;

function TPipeClient.Stats: TPipeClientStats;
var
  LCount: UInt64;
  LTotal: UInt64;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.BytesSent := PipeAtomicRead64(FBytesSent);
  Result.BytesReceived := PipeAtomicRead64(FBytesReceived);
  Result.MessagesSent := PipeAtomicRead64(FMessagesSent);
  Result.MessagesReceived := PipeAtomicRead64(FMessagesReceived);
  Result.ReconnectAttempts := PipeAtomicGet(FReconnectAttempts);
  FRpcLock.Enter;
  try
    Result.PendingRequests := FRpcSlots.Count;
  finally
    FRpcLock.Leave;
  end;
  LCount := PipeAtomicRead64(FReqCount);
  if LCount > 0 then
  begin
    LTotal := PipeAtomicRead64(FReqTotalMs);
    Result.AvgRequestLatencyMs := Cardinal(LTotal div LCount);
  end;
  Result.MaxRequestLatencyMs := Cardinal(PipeAtomicRead64(FReqMaxMs));
end;

procedure TPipeClient.SendBytes(const AData: TBytes);
begin
  FWriteLock.Enter;
  try
    if (not FConnected) or (FStream = nil) then
      raise EPipeClosed.Create('cliente nao esta conectado');
    PipeWriteFrame(FStream, TPipeFrame.Msg(AData), MaxMessageSize);
    PipeAtomicWrite64(FLastWriteTick, PipeTickMs);
    PipeAtomicAdd64(FBytesSent, PIPE_FRAME_HEADER_SIZE + UInt64(Length(AData)));
    PipeAtomicAdd64(FMessagesSent, 1);
  finally
    FWriteLock.Leave;
  end;
end;

procedure TPipeClient.SendText(const AText: string);
begin
  SendBytes(PipeUtf8Encode(AText));
end;

end.
