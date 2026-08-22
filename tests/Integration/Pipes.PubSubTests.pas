unit Pipes.PubSubTests;

{ Testes fim-a-fim da camada de topicos (pub/sub): fanout so' para quem assina,
  curingas no fio, retido, tetos, limpeza da assinatura quando a conexao morre,
  encerramento sob publicacao intensa e — o caso que mais custa quando falha —
  reassinatura automatica depois de uma reconexao.

  As REGRAS de casamento estao fixadas em tests/Unit/Pipes.TopicsTests.pas, que
  nao abre conexao nenhuma. Aqui se testa a FIACAO: se o frame certo sai, chega,
  e mexe no estado certo do outro lado.

  Versao DUnitX; espelha a versao FPCUnit em tests/Integration/fpc. }

interface

uses
  DUnitX.TestFramework,
  SysUtils,
  Classes,
  SyncObjs,
  Pipes.Types,
  Pipes.Threading,
  Pipes.Framing,
  Pipes.Topics,
  Pipes.Transport,
  Pipes.Server,
  Pipes.Client;

type
  [TestFixture]
  TPipePubSubTests = class
  private
    FServer: TPipeServer;
    FClients: array[0..2] of TPipeClient;
    FLock: TCriticalSection;      // protege FTopicLog/FPublishLog
    FTopicLog: TStringList;       // 'idx|topico|texto' recebido por cliente
    FPublishLog: TStringList;     // 'topico|texto' visto em OnPublish
    FDeliveredLog: TStringList;   // 'connid|topico|texto|retained' em OnDelivered
    FDeliveryFailedLog: TStringList; // 'connid|topico|texto|retained' em OnDeliveryFailed
    FTopicCount: array[0..2] of Integer; // atomicos
    FRetainedCount: array[0..2] of Integer; // entregas com ARetained = True
    FCliErrCount: array[0..2] of Integer;
    FSrvErrCount: Integer;
    FPublishCount: Integer;
    FDeliveredCount: Integer;
    FDeliveryFailedCount: Integer;
    FSubCount: Integer;           // OnSubscribe no servidor
    FUnsubCount: Integer;
    FSrvConnCount: Integer;
    FSrvDiscCount: Integer;
    FCliConnCount: Integer;
    FCliDiscCount: Integer;
    FLastConnId: TPipeConnectionId;
    // Handlers ('of object'):
    procedure OnCliTopic(Sender: TObject; AConnId: TPipeConnectionId;
      const ATopic: string; const AData: TBytes; ARetained: Boolean);
    procedure OnCliError(Sender: TObject; AConnId: TPipeConnectionId;
      const AError: string);
    procedure OnSrvPublish(Sender: TObject; AConnId: TPipeConnectionId;
      const ATopic: string; const AData: TBytes; ARetained: Boolean);
    procedure OnSrvSubscribe(Sender: TObject; AConnId: TPipeConnectionId;
      const AFilter: string);
    procedure OnSrvUnsubscribe(Sender: TObject; AConnId: TPipeConnectionId;
      const AFilter: string);
    procedure OnSrvDelivered(Sender: TObject; AConnId: TPipeConnectionId;
      const ATopic: string; const AData: TBytes; ARetained: Boolean);
    procedure OnSrvDeliveryFailed(Sender: TObject; AConnId: TPipeConnectionId;
      const ATopic: string; const AData: TBytes; ARetained: Boolean;
      const AError: string);
    procedure OnSrvError(Sender: TObject; AConnId: TPipeConnectionId;
      const AError: string);
    procedure OnSrvClientConnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnSrvClientDisconnected(Sender: TObject;
      AConnId: TPipeConnectionId);
    procedure OnCliConnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnCliDisconnected(Sender: TObject; AConnId: TPipeConnectionId);
    // Para Assert.WillRaise:
    procedure DoSubscribeFiltroInvalido;
    procedure DoPublishTopicoInvalidoNoServidor;
    procedure DoPublishDesconectado;
    procedure DoPublishBatchTopicoInvalidoNoServidor;
    // Infra:
    function IndexOfClient(Sender: TObject): Integer;
    procedure OpenServer(ADispatchMode: TPipeDispatchMode = pdmPool;
      AMaxMessageSize: Cardinal = 0);
    procedure AddClient(AIndex: Integer);
    function WaitCount(var ACounter: Integer; AExpected: Integer;
      ATimeoutMs: Cardinal): Boolean;
    /// Espera o SERVIDOR ter EXATAMENTE AExpected assinantes de ATopic.
    /// Necessario antes de publicar: Subscribe e' assincrono (nao ha ack a
    /// esperar), entao publicar na sequencia daria uma corrida com o registro do
    /// filtro do outro lado. Igualdade, e nao ">=", para servir tambem a espera
    /// oposta — que o filtro tenha SAIDO depois de um Unsubscribe.
    function WaitSubscribers(const ATopic: string; AExpected: Integer;
      ATimeoutMs: Cardinal): Boolean;
    function CountLog(const APrefix: string): Integer;
    function CountLogIn(AList: TStringList; const APrefix: string): Integer;
  public
    [Setup] procedure SetUp;
    [TearDown] procedure TearDown;
  published
    [Test] procedure Fanout_SoQuemAssinaRecebe;
    [Test] procedure Fanout_CuringasNoFio;
    [Test] procedure Unsubscribe_ParaDeReceber;
    [Test] procedure SubscribeIdempotente_UmaCopiaPorMensagem;
    [Test] procedure AssinaturaMorreComAConexao;
    [Test] procedure AssinaturaMorreNaQuedaAbrupta;
    [Test] procedure Retido_ChegaAQuemAssinaDepois;
    [Test] procedure Retido_AoVivoNaoVemMarcado;
    [Test] procedure Retido_CorpoVazioApaga;
    [Test] procedure Retido_TetoDescartaOMaisAntigo;
    [Test] procedure TetoDeAssinaturas_RecusaAvisandoOsDoisLados;
    [Test] procedure FiltroInvalido_LevantaNoCliente;
    [Test] procedure TopicoInvalido_LevantaNoServidor;
    [Test] procedure PublishDesconectado_Levanta;
    [Test] procedure PublishDoCliente_SemRelayNaoAlcancaOsOutros;
    [Test] procedure PublishDoCliente_ComRelayAlcancaOsOutros;
    [Test] procedure Resubscribe_AposReconexaoAutomatica;
    [Test] procedure Stop_ComPublicacaoIntensa_TerminaEm2s;
    [Test] procedure PublishBatch_ItensSoVaoParaQuemAssinaCadaTopico;
    [Test] procedure PublishBatch_RetainPorItem_ChegaAQuemAssinaDepois;
    [Test] procedure PublishBatch_RetainAoVivo_NaoMarcaARetainedParaQuemJaAssinava;
    [Test] procedure PublishBatch_TopicoInvalido_NaoPublicaNadaDoLote;
    [Test] procedure PublishBatch_DoCliente_SemRelayVaiSoParaOnPublish;
    [Test] procedure OnDelivered_FanOut_UmaVezPorAssinante;
    [Test] procedure OnDelivered_Retido_ChegaComARetainedTrue;
    [Test] procedure OnDelivered_PublishBatch_UmPorItemPorConexao;
    [Test] procedure OnDeliveryFailed_PayloadExcedeMaxMessageSize;
  end;

implementation

var
  GNameSeq: Integer;

function UniquePipeName: string;
begin
  Result := 'pipes_faa_pubsub_' + IntToStr(Int64(PipeTickMs)) + '_' +
    IntToStr(PipeAtomicInc(GNameSeq));
end;

// Length() e' NativeInt no Win64 e AreEqual<T> nao infere T com argumentos de
// tipos diferentes (E2532) — mesmo helper dos outros fixtures.
procedure EqualInt(AExpected, AActual: Integer); overload;
begin
  Assert.AreEqual(AExpected, AActual);
end;

procedure EqualInt(AExpected, AActual: Integer; const AMsg: string); overload;
begin
  Assert.AreEqual(AExpected, AActual, AMsg);
end;

{ TPipePubSubTests }

procedure TPipePubSubTests.SetUp;
var
  I: Integer;
begin
  FLock := TCriticalSection.Create;
  FTopicLog := TStringList.Create;
  FPublishLog := TStringList.Create;
  FDeliveredLog := TStringList.Create;
  FDeliveryFailedLog := TStringList.Create;
  for I := 0 to 2 do
  begin
    FClients[I] := nil;
    FTopicCount[I] := 0;
    FRetainedCount[I] := 0;
    FCliErrCount[I] := 0;
  end;
  FSrvErrCount := 0;
  FPublishCount := 0;
  FDeliveredCount := 0;
  FDeliveryFailedCount := 0;
  FSubCount := 0;
  FUnsubCount := 0;
  FSrvConnCount := 0;
  FSrvDiscCount := 0;
  FCliConnCount := 0;
  FCliDiscCount := 0;
  FLastConnId := 0;
end;

procedure TPipePubSubTests.TearDown;
var
  I: Integer;
begin
  for I := 0 to 2 do
    FreeAndNil(FClients[I]); // Disconnect no destructor
  FreeAndNil(FServer);       // Stop no destructor
  FreeAndNil(FTopicLog);
  FreeAndNil(FPublishLog);
  FreeAndNil(FDeliveredLog);
  FreeAndNil(FDeliveryFailedLog);
  FreeAndNil(FLock);
end;

function TPipePubSubTests.IndexOfClient(Sender: TObject): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to 2 do
    if FClients[I] = Sender then
      Exit(I);
end;

function TPipePubSubTests.WaitCount(var ACounter: Integer;
  AExpected: Integer; ATimeoutMs: Cardinal): Boolean;
var
  LDeadline: UInt64;
begin
  LDeadline := PipeTickMs + ATimeoutMs;
  while (PipeAtomicGet(ACounter) < AExpected) and (PipeTickMs < LDeadline) do
    Sleep(5);
  Result := PipeAtomicGet(ACounter) >= AExpected;
end;

function TPipePubSubTests.WaitSubscribers(const ATopic: string;
  AExpected: Integer; ATimeoutMs: Cardinal): Boolean;
var
  LDeadline: UInt64;
begin
  LDeadline := PipeTickMs + ATimeoutMs;
  while (FServer.SubscriberCount(ATopic) <> AExpected) and
        (PipeTickMs < LDeadline) do
    Sleep(5);
  Result := FServer.SubscriberCount(ATopic) = AExpected;
end;

function TPipePubSubTests.CountLog(const APrefix: string): Integer;
begin
  Result := CountLogIn(FTopicLog, APrefix);
end;

function TPipePubSubTests.CountLogIn(AList: TStringList;
  const APrefix: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  FLock.Enter;
  try
    for I := 0 to AList.Count - 1 do
      if Pos(APrefix, AList[I]) = 1 then
        Inc(Result);
  finally
    FLock.Leave;
  end;
end;

{ --- handlers --- }

procedure TPipePubSubTests.OnCliTopic(Sender: TObject;
  AConnId: TPipeConnectionId; const ATopic: string; const AData: TBytes;
  ARetained: Boolean);
var
  LIdx: Integer;
begin
  LIdx := IndexOfClient(Sender);
  FLock.Enter;
  try
    FTopicLog.Add(IntToStr(LIdx) + '|' + ATopic + '|' + PipeUtf8Decode(AData));
  finally
    FLock.Leave;
  end;
  if LIdx >= 0 then
  begin
    if ARetained then
      PipeAtomicInc(FRetainedCount[LIdx]);
    PipeAtomicInc(FTopicCount[LIdx]); // por ultimo: quem espera por ele ve o resto pronto
  end;
end;

procedure TPipePubSubTests.OnCliError(Sender: TObject;
  AConnId: TPipeConnectionId; const AError: string);
var
  LIdx: Integer;
begin
  LIdx := IndexOfClient(Sender);
  if LIdx >= 0 then
    PipeAtomicInc(FCliErrCount[LIdx]);
end;

procedure TPipePubSubTests.OnSrvPublish(Sender: TObject;
  AConnId: TPipeConnectionId; const ATopic: string; const AData: TBytes;
  ARetained: Boolean);
begin
  FLock.Enter;
  try
    FPublishLog.Add(ATopic + '|' + PipeUtf8Decode(AData));
  finally
    FLock.Leave;
  end;
  PipeAtomicInc(FPublishCount);
end;

procedure TPipePubSubTests.OnSrvSubscribe(Sender: TObject;
  AConnId: TPipeConnectionId; const AFilter: string);
begin
  PipeAtomicInc(FSubCount);
end;

procedure TPipePubSubTests.OnSrvUnsubscribe(Sender: TObject;
  AConnId: TPipeConnectionId; const AFilter: string);
begin
  PipeAtomicInc(FUnsubCount);
end;

procedure TPipePubSubTests.OnSrvDelivered(Sender: TObject;
  AConnId: TPipeConnectionId; const ATopic: string; const AData: TBytes;
  ARetained: Boolean);
begin
  FLock.Enter;
  try
    FDeliveredLog.Add(IntToStr(AConnId) + '|' + ATopic + '|' +
      PipeUtf8Decode(AData) + '|' + BoolToStr(ARetained, True));
  finally
    FLock.Leave;
  end;
  PipeAtomicInc(FDeliveredCount);
end;

procedure TPipePubSubTests.OnSrvDeliveryFailed(Sender: TObject;
  AConnId: TPipeConnectionId; const ATopic: string; const AData: TBytes;
  ARetained: Boolean; const AError: string);
begin
  FLock.Enter;
  try
    FDeliveryFailedLog.Add(IntToStr(AConnId) + '|' + ATopic + '|' +
      PipeUtf8Decode(AData) + '|' + BoolToStr(ARetained, True));
  finally
    FLock.Leave;
  end;
  PipeAtomicInc(FDeliveryFailedCount);
end;

procedure TPipePubSubTests.OnSrvError(Sender: TObject;
  AConnId: TPipeConnectionId; const AError: string);
begin
  PipeAtomicInc(FSrvErrCount);
end;

procedure TPipePubSubTests.OnSrvClientConnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  FLock.Enter;
  try
    FLastConnId := AConnId;
  finally
    FLock.Leave;
  end;
  PipeAtomicInc(FSrvConnCount);
end;

procedure TPipePubSubTests.OnSrvClientDisconnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  PipeAtomicInc(FSrvDiscCount);
end;

procedure TPipePubSubTests.OnCliConnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  PipeAtomicInc(FCliConnCount);
end;

procedure TPipePubSubTests.OnCliDisconnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  PipeAtomicInc(FCliDiscCount);
end;

procedure TPipePubSubTests.DoSubscribeFiltroInvalido;
begin
  FClients[0].Subscribe('caixa.#.status');
end;

procedure TPipePubSubTests.DoPublishTopicoInvalidoNoServidor;
begin
  FServer.PublishText('caixa..status', 'x');
end;

procedure TPipePubSubTests.DoPublishDesconectado;
begin
  FClients[0].PublishText('caixa.3.status', 'x');
end;

procedure TPipePubSubTests.DoPublishBatchTopicoInvalidoNoServidor;
var
  LItems: TArray<TPipePublishItem>;
begin
  SetLength(LItems, 2);
  LItems[0].Topic := 'caixa.3.status'; // valido
  LItems[0].Payload := PipeUtf8Encode('x');
  LItems[1].Topic := 'caixa..status'; // invalido: segmento vazio
  LItems[1].Payload := PipeUtf8Encode('y');
  FServer.PublishBatch(LItems);
end;

{ --- infra --- }

procedure TPipePubSubTests.OpenServer(ADispatchMode: TPipeDispatchMode;
  AMaxMessageSize: Cardinal);
begin
  FServer := TPipeServer.Create(UniquePipeName);
  FServer.DispatchMode := ADispatchMode;
  if AMaxMessageSize <> 0 then
    FServer.MaxMessageSize := AMaxMessageSize;
  FServer.OnPublish := OnSrvPublish;
  FServer.OnSubscribe := OnSrvSubscribe;
  FServer.OnUnsubscribe := OnSrvUnsubscribe;
  FServer.OnDelivered := OnSrvDelivered;
  FServer.OnDeliveryFailed := OnSrvDeliveryFailed;
  FServer.OnError := OnSrvError;
  FServer.OnClientConnected := OnSrvClientConnected;
  FServer.OnClientDisconnected := OnSrvClientDisconnected;
  FServer.Listen;
end;

procedure TPipePubSubTests.AddClient(AIndex: Integer);
begin
  FClients[AIndex] := TPipeClient.Create(FServer.Address);
  FClients[AIndex].OnTopicMessage := OnCliTopic;
  FClients[AIndex].OnError := OnCliError;
  FClients[AIndex].OnConnected := OnCliConnected;
  FClients[AIndex].OnDisconnected := OnCliDisconnected;
  FClients[AIndex].Connect(3000);
end;

{ --- fanout --- }

procedure TPipePubSubTests.Fanout_SoQuemAssinaRecebe;
begin
  OpenServer;
  AddClient(0);
  AddClient(1);
  AddClient(2);
  FClients[0].Subscribe('caixa.3.status');
  FClients[1].Subscribe('caixa.4.status');
  // O cliente 2 nao assina nada: e' a metade do teste que costuma faltar.
  Assert.IsTrue(WaitSubscribers('caixa.3.status', 1, 3000),
    'servidor nao registrou a assinatura do cliente 0');
  Assert.IsTrue(WaitSubscribers('caixa.4.status', 1, 3000),
    'servidor nao registrou a assinatura do cliente 1');

  FServer.PublishText('caixa.3.status', 'aberto');
  Assert.IsTrue(WaitCount(FTopicCount[0], 1, 3000), 'assinante nao recebeu');
  Sleep(150); // janela para uma entrega indevida aparecer
  EqualInt(0, PipeAtomicGet(FTopicCount[1]),
    'cliente 1 nao devia receber topico de outro caixa');
  EqualInt(0, PipeAtomicGet(FTopicCount[2]),
    'cliente 2 nao assinou nada e nao devia receber');
  EqualInt(1, CountLog('0|caixa.3.status|aberto'));
end;

procedure TPipePubSubTests.Fanout_CuringasNoFio;
begin
  OpenServer;
  AddClient(0);
  AddClient(1);
  FClients[0].Subscribe('caixa.*.status'); // um segmento
  FClients[1].Subscribe('caixa.#');        // o resto
  Assert.IsTrue(WaitSubscribers('caixa.3.status', 2, 3000));

  FServer.PublishText('caixa.3.status', 'a');       // casa nos dois
  FServer.PublishText('caixa.3.venda.item', 'b');   // so' no '#'
  Assert.IsTrue(WaitCount(FTopicCount[0], 1, 3000),
    'curinga de um segmento nao entregou');
  Assert.IsTrue(WaitCount(FTopicCount[1], 2, 3000),
    'curinga de resto nao entregou as duas');
  Sleep(150);
  EqualInt(1, PipeAtomicGet(FTopicCount[0]),
    'caixa.*.status nao devia alcancar tres segmentos abaixo');
end;

procedure TPipePubSubTests.Unsubscribe_ParaDeReceber;
begin
  OpenServer;
  AddClient(0);
  FClients[0].Subscribe('caixa.#');
  Assert.IsTrue(WaitSubscribers('caixa.3.status', 1, 3000));
  FServer.PublishText('caixa.3.status', 'primeira');
  Assert.IsTrue(WaitCount(FTopicCount[0], 1, 3000));

  FClients[0].Unsubscribe('caixa.#');
  Assert.IsTrue(WaitSubscribers('caixa.3.status', 0, 3000),
    'servidor nao removeu a assinatura');
  Assert.IsTrue(WaitCount(FUnsubCount, 1, 3000), 'OnUnsubscribe nao disparou');
  EqualInt(0, Length(FClients[0].Subscriptions));

  FServer.PublishText('caixa.3.status', 'segunda');
  Sleep(200);
  EqualInt(1, PipeAtomicGet(FTopicCount[0]),
    'nao devia receber depois do Unsubscribe');
end;

procedure TPipePubSubTests.SubscribeIdempotente_UmaCopiaPorMensagem;
begin
  OpenServer;
  AddClient(0);
  // Dois filtros que alcancam o MESMO topico, mais um repetido: a conexao
  // recebe UMA copia da mensagem, nao uma por filtro que casa.
  FClients[0].Subscribe('caixa.#');
  FClients[0].Subscribe('caixa.#');
  FClients[0].Subscribe('caixa.*.status');
  Assert.IsTrue(WaitSubscribers('caixa.3.status', 1, 3000));
  EqualInt(2, Length(FClients[0].Subscriptions),
    'filtro repetido nao devia entrar duas vezes');
  EqualInt(2, Length(FServer.ClientSubscriptions(FLastConnId)));

  FServer.PublishText('caixa.3.status', 'uma vez');
  Assert.IsTrue(WaitCount(FTopicCount[0], 1, 3000));
  Sleep(200);
  EqualInt(1, PipeAtomicGet(FTopicCount[0]),
    'dois filtros casando nao podem duplicar a entrega');
end;

{ --- ciclo de vida da assinatura --- }

procedure TPipePubSubTests.AssinaturaMorreComAConexao;
var
  LConnId: TPipeConnectionId;
begin
  OpenServer;
  AddClient(0);
  FClients[0].Subscribe('caixa.#');
  Assert.IsTrue(WaitSubscribers('caixa.3.status', 1, 3000));
  FLock.Enter;
  try
    LConnId := FLastConnId;
  finally
    FLock.Leave;
  end;

  FClients[0].Disconnect;
  Assert.IsTrue(WaitCount(FSrvDiscCount, 1, 3000), 'servidor nao viu a saida');
  EqualInt(0, FServer.SubscriberCount('caixa.3.status'),
    'a assinatura tinha de morrer com a conexao');
  EqualInt(0, Length(FServer.ClientSubscriptions(LConnId)));
  // Publicar sem assinante nao levanta nem enfileira nada.
  FServer.PublishText('caixa.3.status', 'no vacuo');
end;

procedure TPipePubSubTests.AssinaturaMorreNaQuedaAbrupta;
var
  LEp: TPipeEndpoint;
  LStream: TStream;
  LDeadline: UInt64;
begin
  // Queda abrupta de verdade: endpoint cru, assina, e desaparece sem despedida
  // (mesmo padrao do AbruptClientCycle em Pipes.StressTests). E' aqui que uma
  // tabela global de topico->conexoes vazaria em silencio.
  OpenServer;
  LEp := PipeConnect(FServer.Address, 3000);
  try
    Assert.IsTrue(WaitCount(FSrvConnCount, 1, 5000), 'conexao nao foi aceita');
    LStream := TPipeEndpointStream.Create(LEp);
    try
      PipeWriteFrame(LStream, PipeSubscribeFrame('caixa.#'),
        PIPES_DEFAULT_MAX_MESSAGE_SIZE);
    finally
      LStream.Free;
    end;
    Assert.IsTrue(WaitSubscribers('caixa.3.status', 1, 3000),
      'servidor nao registrou a assinatura');
  finally
    LEp.Free; // do ponto de vista do servidor, o processo do cliente morreu
  end;
  Assert.IsTrue(WaitCount(FSrvDiscCount, 1, 5000), 'servidor nao viu a queda');
  LDeadline := PipeTickMs + 3000;
  while (FServer.SubscriberCount('caixa.3.status') > 0) and
        (PipeTickMs < LDeadline) do
    Sleep(5);
  EqualInt(0, FServer.SubscriberCount('caixa.3.status'),
    'assinatura vazou depois da queda abrupta');
end;

{ --- retido --- }

procedure TPipePubSubTests.Retido_ChegaAQuemAssinaDepois;
begin
  OpenServer;
  // Publicado ANTES de existir qualquer assinante — e' esse o ponto: sem
  // retain, a mensagem teria ido para ninguem e nada a traria de volta.
  FServer.PublishText('caixa.3.status', 'aberto', True);
  FServer.PublishText('caixa.4.status', 'fechado', True);
  AddClient(0);
  FClients[0].Subscribe('caixa.3.#');
  Assert.IsTrue(WaitCount(FTopicCount[0], 1, 3000),
    'retido nao chegou na assinatura');
  Sleep(200);
  EqualInt(1, PipeAtomicGet(FTopicCount[0]),
    'so o retido que casa com o filtro devia chegar');
  EqualInt(1, CountLog('0|caixa.3.status|aberto'));
  EqualInt(1, PipeAtomicGet(FRetainedCount[0]),
    'catch-up tinha de chegar marcado como retido');
end;

procedure TPipePubSubTests.Retido_AoVivoNaoVemMarcado;
begin
  // O outro lado da moeda, e a parte facil de errar: publicar COM retain para
  // quem JA esta assinando entrega uma mensagem ao vivo, e ao vivo nunca e'
  // historico. Se o bit passasse adiante, o app trataria a venda de agora como
  // catch-up e nao a contaria.
  OpenServer;
  AddClient(0);
  FClients[0].Subscribe('caixa.#');
  Assert.IsTrue(WaitSubscribers('caixa.3.status', 1, 3000));
  FServer.PublishText('caixa.3.status', 'aberto', True); // retain + assinante
  Assert.IsTrue(WaitCount(FTopicCount[0], 1, 3000));
  EqualInt(0, PipeAtomicGet(FRetainedCount[0]),
    'publicacao ao vivo nao pode vir marcada como retida');
  // ... e o valor ficou guardado do mesmo jeito, para o proximo assinante.
  AddClient(1);
  FClients[1].Subscribe('caixa.#');
  Assert.IsTrue(WaitCount(FTopicCount[1], 1, 3000));
  EqualInt(1, PipeAtomicGet(FRetainedCount[1]),
    'o segundo cliente devia receber o retido, marcado');
end;

procedure TPipePubSubTests.Retido_CorpoVazioApaga;
begin
  OpenServer;
  FServer.PublishText('caixa.3.status', 'aberto', True);
  FServer.Publish('caixa.3.status', nil, True); // corpo vazio: apaga
  AddClient(0);
  FClients[0].Subscribe('caixa.#');
  Assert.IsTrue(WaitSubscribers('caixa.3.status', 1, 3000));
  Sleep(250);
  EqualInt(0, PipeAtomicGet(FTopicCount[0]),
    'valor apagado nao devia ser entregue');
end;

procedure TPipePubSubTests.Retido_TetoDescartaOMaisAntigo;
begin
  OpenServer;
  FServer.MaxRetained := 2;
  FServer.PublishText('t.1', 'um', True);
  FServer.PublishText('t.2', 'dois', True);
  FServer.PublishText('t.3', 'tres', True); // despeja 't.1'
  AddClient(0);
  FClients[0].Subscribe('t.#');
  Assert.IsTrue(WaitCount(FTopicCount[0], 2, 3000), 'retidos nao chegaram');
  Sleep(200);
  EqualInt(2, PipeAtomicGet(FTopicCount[0]),
    'o teto tinha de descartar o mais antigo');
  EqualInt(0, CountLog('0|t.1|'));
  EqualInt(1, CountLog('0|t.2|dois'));
  EqualInt(1, CountLog('0|t.3|tres'));
end;

{ --- recusas --- }

procedure TPipePubSubTests.TetoDeAssinaturas_RecusaAvisandoOsDoisLados;
begin
  OpenServer;
  FServer.MaxSubscriptionsPerClient := 2;
  AddClient(0);
  FClients[0].Subscribe('a.#');
  FClients[0].Subscribe('b.#');
  Assert.IsTrue(WaitSubscribers('a.x', 1, 3000));
  Assert.IsTrue(WaitSubscribers('b.x', 1, 3000));

  FClients[0].Subscribe('c.#'); // acima do teto
  // A recusa aparece nos DOIS lados: OnError do servidor (quem recusou) e
  // OnError do cliente (via reply de erro com corrId 0). Silencio no cliente
  // seria o pior desfecho — ele esperaria mensagens que nunca viriam.
  Assert.IsTrue(WaitCount(FSrvErrCount, 1, 3000),
    'servidor nao registrou a recusa');
  Assert.IsTrue(WaitCount(FCliErrCount[0], 1, 3000),
    'cliente nao foi avisado da recusa');
  EqualInt(2, Length(FServer.ClientSubscriptions(FLastConnId)),
    'o filtro recusado nao devia entrar');
  EqualInt(1, FServer.ClientCount, 'a conexao devia continuar de pe');
  EqualInt(0, FServer.SubscriberCount('c.x'));
end;

procedure TPipePubSubTests.FiltroInvalido_LevantaNoCliente;
begin
  OpenServer;
  AddClient(0);
  // Erro de programacao no proprio processo: levanta na hora, na linha errada,
  // em vez de virar um frame que o servidor recusaria depois.
  Assert.WillRaise(DoSubscribeFiltroInvalido, EPipeError);
  EqualInt(0, Length(FClients[0].Subscriptions));
end;

procedure TPipePubSubTests.TopicoInvalido_LevantaNoServidor;
begin
  OpenServer;
  Assert.WillRaise(DoPublishTopicoInvalidoNoServidor, EPipeError);
end;

procedure TPipePubSubTests.PublishDesconectado_Levanta;
begin
  OpenServer;
  FClients[0] := TPipeClient.Create(FServer.Address);
  // Publicar e' um acontecimento com hora, nao uma intencao guardada como o
  // Subscribe: sem sessao, levanta.
  Assert.WillRaise(DoPublishDesconectado, EPipeClosed);
end;

{ --- publicacao vinda do cliente --- }

procedure TPipePubSubTests.PublishDoCliente_SemRelayNaoAlcancaOsOutros;
begin
  OpenServer;
  AddClient(0);
  AddClient(1);
  FClients[1].Subscribe('caixa.#');
  Assert.IsTrue(WaitSubscribers('caixa.3.status', 1, 3000));

  FClients[0].PublishText('caixa.3.status', 'do cliente');
  Assert.IsTrue(WaitCount(FPublishCount, 1, 3000),
    'OnPublish nao disparou no servidor');
  Sleep(200);
  EqualInt(0, PipeAtomicGet(FTopicCount[1]),
    'sem RelayClientPublish, um cliente nao injeta nos outros');
  FLock.Enter;
  try
    Assert.AreEqual('caixa.3.status|do cliente', FPublishLog[0]);
  finally
    FLock.Leave;
  end;
end;

procedure TPipePubSubTests.PublishDoCliente_ComRelayAlcancaOsOutros;
begin
  OpenServer;
  FServer.RelayClientPublish := True;
  AddClient(0);
  AddClient(1);
  FClients[1].Subscribe('caixa.#');
  FClients[0].Subscribe('caixa.#'); // tambem assina: o relay inclui o autor
  Assert.IsTrue(WaitSubscribers('caixa.3.status', 2, 3000));

  FClients[0].PublishText('caixa.3.status', 'do cliente');
  Assert.IsTrue(WaitCount(FTopicCount[1], 1, 3000),
    'o outro assinante nao recebeu o relay');
  Assert.IsTrue(WaitCount(FTopicCount[0], 1, 3000),
    'o proprio autor assinante tambem devia receber');
  Assert.IsTrue(WaitCount(FPublishCount, 1, 3000));
end;

{ --- reconexao --- }

procedure TPipePubSubTests.Resubscribe_AposReconexaoAutomatica;
var
  LName: string;
begin
  // O caso que doi: a assinatura vive na CONEXAO do lado do servidor, entao uma
  // reconexao devolveria uma sessao viva e muda se o cliente nao reenviasse os
  // filtros. O sintoma (mensagens que param de chegar depois de uma reconexao
  // que o app nem viu) nao se parece nada com a causa.
  LName := UniquePipeName;
  FServer := TPipeServer.Create(LName);
  FServer.OnClientConnected := OnSrvClientConnected;
  FServer.OnError := OnSrvError;
  FServer.Listen;

  FClients[0] := TPipeClient.Create(LName);
  FClients[0].OnTopicMessage := OnCliTopic;
  FClients[0].OnConnected := OnCliConnected;
  FClients[0].OnDisconnected := OnCliDisconnected;
  FClients[0].AutoReconnect := True;
  FClients[0].ReconnectDelayMs := 300;
  FClients[0].Connect(3000);
  Assert.IsTrue(WaitCount(FCliConnCount, 1, 3000),
    'primeira conexao nao confirmou');
  FClients[0].Subscribe('caixa.#');
  Assert.IsTrue(WaitSubscribers('caixa.3.status', 1, 3000));

  FServer.Stop;
  Assert.IsTrue(WaitCount(FCliDiscCount, 1, 5000), 'queda nao notificada');
  FServer.Listen; // mesmo nome: o cliente reconecta
  Assert.IsTrue(WaitCount(FCliConnCount, 2, 10000), 'cliente nao reconectou');

  // Nenhum Subscribe novo aqui: quem tem de reassinar e' a lib.
  Assert.IsTrue(WaitSubscribers('caixa.3.status', 1, 5000),
    'assinatura nao foi reenviada na reconexao');
  FServer.PublishText('caixa.3.status', 'depois da reconexao');
  Assert.IsTrue(WaitCount(FTopicCount[0], 1, 5000),
    'publicacao pos-reconexao nao chegou');
  EqualInt(1, CountLog('0|caixa.3.status|depois da reconexao'));
  EqualInt(1, Length(FClients[0].Subscriptions),
    'o app nao devia ter de reassinar');
end;

{ --- encerramento --- }

procedure TPipePubSubTests.Stop_ComPublicacaoIntensa_TerminaEm2s;
var
  I: Integer;
  T0: UInt64;
begin
  OpenServer;
  AddClient(0);
  AddClient(1);
  AddClient(2);
  for I := 0 to 2 do
    FClients[I].Subscribe('carga.#');
  Assert.IsTrue(WaitSubscribers('carga.x', 3, 3000));

  // Fanout para 3 assinantes, 300 vezes: o Stop tem de vencer a fila de
  // escritas em vez de esperar por ela (detector de deadlock).
  for I := 1 to 300 do
    FServer.PublishText('carga.x', 'p' + IntToStr(I));
  T0 := PipeTickMs;
  FServer.Stop;
  Assert.IsTrue(PipeTickMs - T0 < 2000,
    'Stop sob publicacao intensa demorou demais (deadlock?)');
  Assert.IsFalse(FServer.Active, 'servidor devia estar inativo');
  Assert.IsTrue(WaitCount(FCliDiscCount, 3, 3000),
    'os clientes nao perceberam o Stop');
end;

{ --- PublishBatch --- }

procedure TPipePubSubTests.PublishBatch_ItensSoVaoParaQuemAssinaCadaTopico;
var
  LItems: TArray<TPipePublishItem>;
begin
  OpenServer;
  AddClient(0);
  AddClient(1);
  AddClient(2);
  FClients[0].Subscribe('caixa.3.status');
  FClients[1].Subscribe('caixa.4.status');
  // O cliente 2 nao assina nada: item sem assinante nao pode virar Write nenhum.
  Assert.IsTrue(WaitSubscribers('caixa.3.status', 1, 3000));
  Assert.IsTrue(WaitSubscribers('caixa.4.status', 1, 3000));

  SetLength(LItems, 2);
  LItems[0].Topic := 'caixa.3.status';
  LItems[0].Payload := PipeUtf8Encode('aberto');
  LItems[1].Topic := 'caixa.4.status';
  LItems[1].Payload := PipeUtf8Encode('fechado');
  FServer.PublishBatch(LItems);

  Assert.IsTrue(WaitCount(FTopicCount[0], 1, 3000),
    'cliente 0 nao recebeu o item do seu topico');
  Assert.IsTrue(WaitCount(FTopicCount[1], 1, 3000),
    'cliente 1 nao recebeu o item do seu topico');
  Sleep(150);
  EqualInt(0, PipeAtomicGet(FTopicCount[2]),
    'cliente 2 nao assinou nada e nao devia receber');
  EqualInt(1, CountLog('0|caixa.3.status|aberto'));
  EqualInt(1, CountLog('1|caixa.4.status|fechado'));
end;

procedure TPipePubSubTests.PublishBatch_RetainPorItem_ChegaAQuemAssinaDepois;
var
  LItems: TArray<TPipePublishItem>;
begin
  OpenServer;
  SetLength(LItems, 2);
  LItems[0].Topic := 't.1';
  LItems[0].Payload := PipeUtf8Encode('um');
  LItems[0].Retain := True;
  LItems[1].Topic := 't.2';
  LItems[1].Payload := PipeUtf8Encode('dois');
  LItems[1].Retain := False; // nao devia sobreviver para quem assina depois
  FServer.PublishBatch(LItems);

  AddClient(0);
  FClients[0].Subscribe('t.#');
  Assert.IsTrue(WaitCount(FTopicCount[0], 1, 3000), 'retido do lote nao chegou');
  Sleep(200);
  EqualInt(1, PipeAtomicGet(FTopicCount[0]),
    'so o item com Retain=True devia sobreviver para o novo assinante');
  EqualInt(1, CountLog('0|t.1|um'));
  EqualInt(0, CountLog('0|t.2|'));
end;

procedure TPipePubSubTests.PublishBatch_RetainAoVivo_NaoMarcaARetainedParaQuemJaAssinava;
var
  LItems: TArray<TPipePublishItem>;
begin
  // Regressao: PublishBatch chegou a gravar PIPE_FLAG_RETAIN no fio direto do
  // campo Retain do item, mesmo em entrega AO VIVO — um assinante ja conectado
  // recebia ARetained=True (enganado sobre "isto e' historico?"). A regra e' a
  // mesma de FanOut: o bit so' liga no replay de SendRetained.
  OpenServer;
  AddClient(0);
  FClients[0].Subscribe('caixa.3.status');
  Assert.IsTrue(WaitSubscribers('caixa.3.status', 1, 3000));

  SetLength(LItems, 1);
  LItems[0].Topic := 'caixa.3.status';
  LItems[0].Payload := PipeUtf8Encode('aberto');
  LItems[0].Retain := True;
  FServer.PublishBatch(LItems);

  Assert.IsTrue(WaitCount(FTopicCount[0], 1, 3000), 'assinante nao recebeu o item');
  EqualInt(0, PipeAtomicGet(FRetainedCount[0]),
    'entrega AO VIVO nao pode chegar marcada como ARetained=True');
end;

procedure TPipePubSubTests.PublishBatch_TopicoInvalido_NaoPublicaNadaDoLote;
begin
  OpenServer;
  AddClient(0);
  FClients[0].Subscribe('caixa.#');
  Assert.IsTrue(WaitSubscribers('caixa.3.status', 1, 3000));
  Assert.WillRaise(DoPublishBatchTopicoInvalidoNoServidor, EPipeError);
  Sleep(150);
  EqualInt(0, PipeAtomicGet(FTopicCount[0]),
    'topico invalido no lote nao pode deixar os outros itens passarem');
end;

procedure TPipePubSubTests.PublishBatch_DoCliente_SemRelayVaiSoParaOnPublish;
var
  LItems: TArray<TPipePublishItem>;
begin
  OpenServer;
  AddClient(0);
  AddClient(1);
  FClients[1].Subscribe('caixa.#');
  Assert.IsTrue(WaitSubscribers('caixa.3.status', 1, 3000));

  SetLength(LItems, 2);
  LItems[0].Topic := 'caixa.3.status';
  LItems[0].Payload := PipeUtf8Encode('a');
  LItems[1].Topic := 'caixa.4.status';
  LItems[1].Payload := PipeUtf8Encode('b');
  FClients[0].PublishBatch(LItems);

  Assert.IsTrue(WaitCount(FPublishCount, 2, 3000),
    'OnPublish nao viu os dois itens do lote');
  Sleep(150);
  EqualInt(0, PipeAtomicGet(FTopicCount[1]),
    'sem RelayClientPublish, o lote nao alcanca outros clientes');
end;

{ --- OnDelivered / OnDeliveryFailed --- }

procedure TPipePubSubTests.OnDelivered_FanOut_UmaVezPorAssinante;
var
  LConnId0: TPipeConnectionId;
begin
  OpenServer;
  AddClient(0);
  FClients[0].Subscribe('caixa.3.status');
  Assert.IsTrue(WaitSubscribers('caixa.3.status', 1, 3000));
  LConnId0 := FLastConnId; // captura ANTES do cliente 1 conectar (que move FLastConnId)

  AddClient(1); // nao assina nada: nao pode gerar OnDelivered nenhum
  FServer.PublishText('caixa.3.status', 'aberto');

  Assert.IsTrue(WaitCount(FDeliveredCount, 1, 3000),
    'OnDelivered nao disparou para o assinante');
  Sleep(150); // janela para uma segunda entrega indevida aparecer
  EqualInt(1, PipeAtomicGet(FDeliveredCount),
    'OnDelivered devia disparar exatamente uma vez, apenas para quem assina');
  EqualInt(1, CountLogIn(FDeliveredLog,
    IntToStr(LConnId0) + '|caixa.3.status|aberto|False'));
  EqualInt(0, PipeAtomicGet(FDeliveryFailedCount),
    'entrega bem-sucedida nao pode disparar OnDeliveryFailed');
end;

procedure TPipePubSubTests.OnDelivered_Retido_ChegaComARetainedTrue;
begin
  OpenServer;
  FServer.PublishText('caixa.5.status', 'aberto', True); // ninguem assina ainda: so guarda

  AddClient(0);
  FClients[0].Subscribe('caixa.5.status');

  Assert.IsTrue(WaitCount(FTopicCount[0], 1, 3000), 'retido nao chegou ao novo assinante');
  Assert.IsTrue(WaitCount(FDeliveredCount, 1, 3000),
    'OnDelivered nao disparou para o replay do retido');
  EqualInt(1, CountLogIn(FDeliveredLog,
    IntToStr(FLastConnId) + '|caixa.5.status|aberto|True'));
end;

procedure TPipePubSubTests.OnDelivered_PublishBatch_UmPorItemPorConexao;
var
  LItems: TArray<TPipePublishItem>;
begin
  OpenServer;
  AddClient(0);
  AddClient(1);
  FClients[0].Subscribe('caixa.3.status');
  FClients[1].Subscribe('caixa.4.status');
  Assert.IsTrue(WaitSubscribers('caixa.3.status', 1, 3000));
  Assert.IsTrue(WaitSubscribers('caixa.4.status', 1, 3000));

  SetLength(LItems, 2);
  LItems[0].Topic := 'caixa.3.status';
  LItems[0].Payload := PipeUtf8Encode('aberto');
  LItems[1].Topic := 'caixa.4.status';
  LItems[1].Payload := PipeUtf8Encode('fechado');
  FServer.PublishBatch(LItems);

  Assert.IsTrue(WaitCount(FDeliveredCount, 2, 3000),
    'OnDelivered nao disparou para os dois itens do lote');
  Sleep(150);
  EqualInt(2, PipeAtomicGet(FDeliveredCount),
    'cada item do lote pode gerar no maximo um OnDelivered por conexao que casou');
end;

procedure TPipePubSubTests.OnDeliveryFailed_PayloadExcedeMaxMessageSize;
begin
  // MaxMessageSize pequeno o bastante para deixar a assinatura passar (o
  // filtro sozinho cabe) mas pequeno demais para o envelope topico+corpo da
  // publicacao: PipeValidateMaxPayload recusa o Write ANTES de tocar o
  // socket/pipe — falha deterministica, sem depender de uma conexao morrendo
  // na hora certa (essa corrida seria um teste flaky de verdade).
  OpenServer(pdmPool, 40);
  AddClient(0);
  FClients[0].Subscribe('caixa.3.status');
  Assert.IsTrue(WaitSubscribers('caixa.3.status', 1, 3000));

  FServer.PublishText('caixa.3.status', 'este payload excede de sobra o teto configurado');

  Assert.IsTrue(WaitCount(FDeliveryFailedCount, 1, 3000),
    'OnDeliveryFailed nao disparou para o payload grande demais');
  EqualInt(1, CountLogIn(FDeliveryFailedLog,
    IntToStr(FLastConnId) + '|caixa.3.status|'));
  EqualInt(0, PipeAtomicGet(FDeliveredCount),
    'entrega que falhou nao pode contar como OnDelivered');
  Sleep(150);
  EqualInt(0, PipeAtomicGet(FTopicCount[0]),
    'o cliente nao pode ter recebido o payload que nao coube no teto');
end;

initialization
  TDUnitX.RegisterTestFixture(TPipePubSubTests);

end.
