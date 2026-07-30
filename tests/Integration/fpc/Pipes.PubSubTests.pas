unit Pipes.PubSubTests;

{$mode delphi}{$H+}

{ Testes fim-a-fim da camada de topicos (pub/sub): fanout so' para quem assina,
  curingas no fio, retido, tetos, limpeza da assinatura quando a conexao morre,
  encerramento sob publicacao intensa e — o caso que mais custa quando falha —
  reassinatura automatica depois de uma reconexao.

  As REGRAS de casamento estao fixadas em tests/Unit/Pipes.TopicsTests.pas, que
  nao abre conexao nenhuma. Aqui se testa a FIACAO: se o frame certo sai, chega,
  e mexe no estado certo do outro lado.

  Versao FPCUnit; espelha a versao DUnitX em tests/Integration. }

interface

uses
  fpcunit, testregistry,
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
  TPipePubSubTests = class(TTestCase)
  private
    FServer: TPipeServer;
    FClients: array[0..2] of TPipeClient;
    FLock: TCriticalSection;      // protege FTopicLog/FPublishLog
    FTopicLog: TStringList;       // 'idx|topico|texto' recebido por cliente
    FPublishLog: TStringList;     // 'topico|texto' visto em OnPublish
    FTopicCount: array[0..2] of Integer; // atomicos
    FCliErrCount: array[0..2] of Integer;
    FSrvErrCount: Integer;
    FPublishCount: Integer;
    FSubCount: Integer;           // OnSubscribe no servidor
    FUnsubCount: Integer;
    FSrvConnCount: Integer;
    FSrvDiscCount: Integer;
    FCliConnCount: Integer;
    FCliDiscCount: Integer;
    FLastConnId: TPipeConnectionId;
    // Handlers ('of object'):
    procedure OnCliTopic(Sender: TObject; AConnId: TPipeConnectionId;
      const ATopic: string; const AData: TBytes);
    procedure OnCliError(Sender: TObject; AConnId: TPipeConnectionId;
      const AError: string);
    procedure OnSrvPublish(Sender: TObject; AConnId: TPipeConnectionId;
      const ATopic: string; const AData: TBytes);
    procedure OnSrvSubscribe(Sender: TObject; AConnId: TPipeConnectionId;
      const AFilter: string);
    procedure OnSrvUnsubscribe(Sender: TObject; AConnId: TPipeConnectionId;
      const AFilter: string);
    procedure OnSrvError(Sender: TObject; AConnId: TPipeConnectionId;
      const AError: string);
    procedure OnSrvClientConnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnSrvClientDisconnected(Sender: TObject;
      AConnId: TPipeConnectionId);
    procedure OnCliConnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnCliDisconnected(Sender: TObject; AConnId: TPipeConnectionId);
    // Para AssertException:
    procedure DoSubscribeFiltroInvalido;
    procedure DoPublishTopicoInvalidoNoServidor;
    procedure DoPublishDesconectado;
    // Infra:
    function IndexOfClient(Sender: TObject): Integer;
    procedure OpenServer(ADispatchMode: TPipeDispatchMode = pdmPool);
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
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure Fanout_SoQuemAssinaRecebe;
    procedure Fanout_CuringasNoFio;
    procedure Unsubscribe_ParaDeReceber;
    procedure SubscribeIdempotente_UmaCopiaPorMensagem;
    procedure AssinaturaMorreComAConexao;
    procedure AssinaturaMorreNaQuedaAbrupta;
    procedure Retido_ChegaAQuemAssinaDepois;
    procedure Retido_CorpoVazioApaga;
    procedure Retido_TetoDescartaOMaisAntigo;
    procedure TetoDeAssinaturas_RecusaAvisandoOsDoisLados;
    procedure FiltroInvalido_LevantaNoCliente;
    procedure TopicoInvalido_LevantaNoServidor;
    procedure PublishDesconectado_Levanta;
    procedure PublishDoCliente_SemRelayNaoAlcancaOsOutros;
    procedure PublishDoCliente_ComRelayAlcancaOsOutros;
    procedure Resubscribe_AposReconexaoAutomatica;
    procedure Stop_ComPublicacaoIntensa_TerminaEm2s;
  end;

implementation

var
  GNameSeq: Integer;

function UniquePipeName: string;
begin
  Result := 'pipes_faa_pubsub_' + IntToStr(Int64(PipeTickMs)) + '_' +
    IntToStr(PipeAtomicInc(GNameSeq));
end;

{ TPipePubSubTests }

procedure TPipePubSubTests.SetUp;
var
  I: Integer;
begin
  inherited;
  FLock := TCriticalSection.Create;
  FTopicLog := TStringList.Create;
  FPublishLog := TStringList.Create;
  for I := 0 to 2 do
  begin
    FClients[I] := nil;
    FTopicCount[I] := 0;
    FCliErrCount[I] := 0;
  end;
  FSrvErrCount := 0;
  FPublishCount := 0;
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
  FreeAndNil(FLock);
  inherited;
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
var
  I: Integer;
begin
  Result := 0;
  FLock.Enter;
  try
    for I := 0 to FTopicLog.Count - 1 do
      if Pos(APrefix, FTopicLog[I]) = 1 then
        Inc(Result);
  finally
    FLock.Leave;
  end;
end;

{ --- handlers --- }

procedure TPipePubSubTests.OnCliTopic(Sender: TObject;
  AConnId: TPipeConnectionId; const ATopic: string; const AData: TBytes);
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
    PipeAtomicInc(FTopicCount[LIdx]);
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
  AConnId: TPipeConnectionId; const ATopic: string; const AData: TBytes);
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

{ --- infra --- }

procedure TPipePubSubTests.OpenServer(ADispatchMode: TPipeDispatchMode);
begin
  FServer := TPipeServer.Create(UniquePipeName);
  FServer.DispatchMode := ADispatchMode;
  FServer.OnPublish := OnSrvPublish;
  FServer.OnSubscribe := OnSrvSubscribe;
  FServer.OnUnsubscribe := OnSrvUnsubscribe;
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
  AssertTrue('servidor nao registrou a assinatura do cliente 0',
    WaitSubscribers('caixa.3.status', 1, 3000));
  AssertTrue('servidor nao registrou a assinatura do cliente 1',
    WaitSubscribers('caixa.4.status', 1, 3000));

  FServer.PublishText('caixa.3.status', 'aberto');
  AssertTrue('assinante nao recebeu', WaitCount(FTopicCount[0], 1, 3000));
  Sleep(150); // janela para uma entrega indevida aparecer
  AssertEquals('cliente 1 nao devia receber topico de outro caixa',
    0, PipeAtomicGet(FTopicCount[1]));
  AssertEquals('cliente 2 nao assinou nada e nao devia receber',
    0, PipeAtomicGet(FTopicCount[2]));
  AssertEquals(1, CountLog('0|caixa.3.status|aberto'));
end;

procedure TPipePubSubTests.Fanout_CuringasNoFio;
begin
  OpenServer;
  AddClient(0);
  AddClient(1);
  FClients[0].Subscribe('caixa.*.status'); // um segmento
  FClients[1].Subscribe('caixa.#');        // o resto
  AssertTrue(WaitSubscribers('caixa.3.status', 2, 3000));

  FServer.PublishText('caixa.3.status', 'a');       // casa nos dois
  FServer.PublishText('caixa.3.venda.item', 'b');   // so' no '#'
  AssertTrue('curinga de um segmento nao entregou',
    WaitCount(FTopicCount[0], 1, 3000));
  AssertTrue('curinga de resto nao entregou as duas',
    WaitCount(FTopicCount[1], 2, 3000));
  Sleep(150);
  AssertEquals('caixa.*.status nao devia alcancar tres segmentos abaixo',
    1, PipeAtomicGet(FTopicCount[0]));
end;

procedure TPipePubSubTests.Unsubscribe_ParaDeReceber;
begin
  OpenServer;
  AddClient(0);
  FClients[0].Subscribe('caixa.#');
  AssertTrue(WaitSubscribers('caixa.3.status', 1, 3000));
  FServer.PublishText('caixa.3.status', 'primeira');
  AssertTrue(WaitCount(FTopicCount[0], 1, 3000));

  FClients[0].Unsubscribe('caixa.#');
  AssertTrue('servidor nao removeu a assinatura',
    WaitSubscribers('caixa.3.status', 0, 3000));
  AssertTrue('OnUnsubscribe nao disparou', WaitCount(FUnsubCount, 1, 3000));
  AssertEquals(0, Length(FClients[0].Subscriptions));

  FServer.PublishText('caixa.3.status', 'segunda');
  Sleep(200);
  AssertEquals('nao devia receber depois do Unsubscribe',
    1, PipeAtomicGet(FTopicCount[0]));
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
  AssertTrue(WaitSubscribers('caixa.3.status', 1, 3000));
  AssertEquals('filtro repetido nao devia entrar duas vezes',
    2, Length(FClients[0].Subscriptions));
  AssertEquals(2, Length(FServer.ClientSubscriptions(FLastConnId)));

  FServer.PublishText('caixa.3.status', 'uma vez');
  AssertTrue(WaitCount(FTopicCount[0], 1, 3000));
  Sleep(200);
  AssertEquals('dois filtros casando nao podem duplicar a entrega',
    1, PipeAtomicGet(FTopicCount[0]));
end;

{ --- ciclo de vida da assinatura --- }

procedure TPipePubSubTests.AssinaturaMorreComAConexao;
var
  LConnId: TPipeConnectionId;
begin
  OpenServer;
  AddClient(0);
  FClients[0].Subscribe('caixa.#');
  AssertTrue(WaitSubscribers('caixa.3.status', 1, 3000));
  FLock.Enter;
  try
    LConnId := FLastConnId;
  finally
    FLock.Leave;
  end;

  FClients[0].Disconnect;
  AssertTrue('servidor nao viu a saida', WaitCount(FSrvDiscCount, 1, 3000));
  AssertEquals('a assinatura tinha de morrer com a conexao',
    0, FServer.SubscriberCount('caixa.3.status'));
  AssertEquals(0, Length(FServer.ClientSubscriptions(LConnId)));
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
    AssertTrue('conexao nao foi aceita', WaitCount(FSrvConnCount, 1, 5000));
    LStream := TPipeEndpointStream.Create(LEp);
    try
      PipeWriteFrame(LStream, PipeSubscribeFrame('caixa.#'),
        PIPES_DEFAULT_MAX_MESSAGE_SIZE);
    finally
      LStream.Free;
    end;
    AssertTrue('servidor nao registrou a assinatura',
      WaitSubscribers('caixa.3.status', 1, 3000));
  finally
    LEp.Free; // do ponto de vista do servidor, o processo do cliente morreu
  end;
  AssertTrue('servidor nao viu a queda', WaitCount(FSrvDiscCount, 1, 5000));
  LDeadline := PipeTickMs + 3000;
  while (FServer.SubscriberCount('caixa.3.status') > 0) and
        (PipeTickMs < LDeadline) do
    Sleep(5);
  AssertEquals('assinatura vazou depois da queda abrupta',
    0, FServer.SubscriberCount('caixa.3.status'));
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
  AssertTrue('retido nao chegou na assinatura',
    WaitCount(FTopicCount[0], 1, 3000));
  Sleep(200);
  AssertEquals('so o retido que casa com o filtro devia chegar',
    1, PipeAtomicGet(FTopicCount[0]));
  AssertEquals(1, CountLog('0|caixa.3.status|aberto'));
end;

procedure TPipePubSubTests.Retido_CorpoVazioApaga;
begin
  OpenServer;
  FServer.PublishText('caixa.3.status', 'aberto', True);
  FServer.Publish('caixa.3.status', nil, True); // corpo vazio: apaga
  AddClient(0);
  FClients[0].Subscribe('caixa.#');
  AssertTrue(WaitSubscribers('caixa.3.status', 1, 3000));
  Sleep(250);
  AssertEquals('valor apagado nao devia ser entregue',
    0, PipeAtomicGet(FTopicCount[0]));
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
  AssertTrue('retidos nao chegaram', WaitCount(FTopicCount[0], 2, 3000));
  Sleep(200);
  AssertEquals('o teto tinha de descartar o mais antigo',
    2, PipeAtomicGet(FTopicCount[0]));
  AssertEquals(0, CountLog('0|t.1|'));
  AssertEquals(1, CountLog('0|t.2|dois'));
  AssertEquals(1, CountLog('0|t.3|tres'));
end;

{ --- recusas --- }

procedure TPipePubSubTests.TetoDeAssinaturas_RecusaAvisandoOsDoisLados;
begin
  OpenServer;
  FServer.MaxSubscriptionsPerClient := 2;
  AddClient(0);
  FClients[0].Subscribe('a.#');
  FClients[0].Subscribe('b.#');
  AssertTrue(WaitSubscribers('a.x', 1, 3000));
  AssertTrue(WaitSubscribers('b.x', 1, 3000));

  FClients[0].Subscribe('c.#'); // acima do teto
  // A recusa aparece nos DOIS lados: OnError do servidor (quem recusou) e
  // OnError do cliente (via reply de erro com corrId 0). Silencio no cliente
  // seria o pior desfecho — ele esperaria mensagens que nunca viriam.
  AssertTrue('servidor nao registrou a recusa',
    WaitCount(FSrvErrCount, 1, 3000));
  AssertTrue('cliente nao foi avisado da recusa',
    WaitCount(FCliErrCount[0], 1, 3000));
  AssertEquals('o filtro recusado nao devia entrar',
    2, Length(FServer.ClientSubscriptions(FLastConnId)));
  AssertEquals('a conexao devia continuar de pe', 1, FServer.ClientCount);
  AssertEquals(0, FServer.SubscriberCount('c.x'));
end;

procedure TPipePubSubTests.FiltroInvalido_LevantaNoCliente;
begin
  OpenServer;
  AddClient(0);
  // Erro de programacao no proprio processo: levanta na hora, na linha errada,
  // em vez de virar um frame que o servidor recusaria depois.
  AssertException(EPipeError, DoSubscribeFiltroInvalido);
  AssertEquals(0, Length(FClients[0].Subscriptions));
end;

procedure TPipePubSubTests.TopicoInvalido_LevantaNoServidor;
begin
  OpenServer;
  AssertException(EPipeError, DoPublishTopicoInvalidoNoServidor);
end;

procedure TPipePubSubTests.PublishDesconectado_Levanta;
begin
  OpenServer;
  FClients[0] := TPipeClient.Create(FServer.Address);
  // Publicar e' um acontecimento com hora, nao uma intencao guardada como o
  // Subscribe: sem sessao, levanta.
  AssertException(EPipeClosed, DoPublishDesconectado);
end;

{ --- publicacao vinda do cliente --- }

procedure TPipePubSubTests.PublishDoCliente_SemRelayNaoAlcancaOsOutros;
begin
  OpenServer;
  AddClient(0);
  AddClient(1);
  FClients[1].Subscribe('caixa.#');
  AssertTrue(WaitSubscribers('caixa.3.status', 1, 3000));

  FClients[0].PublishText('caixa.3.status', 'do cliente');
  AssertTrue('OnPublish nao disparou no servidor',
    WaitCount(FPublishCount, 1, 3000));
  Sleep(200);
  AssertEquals('sem RelayClientPublish, um cliente nao injeta nos outros',
    0, PipeAtomicGet(FTopicCount[1]));
  FLock.Enter;
  try
    AssertEquals('caixa.3.status|do cliente', FPublishLog[0]);
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
  AssertTrue(WaitSubscribers('caixa.3.status', 2, 3000));

  FClients[0].PublishText('caixa.3.status', 'do cliente');
  AssertTrue('o outro assinante nao recebeu o relay',
    WaitCount(FTopicCount[1], 1, 3000));
  AssertTrue('o proprio autor assinante tambem devia receber',
    WaitCount(FTopicCount[0], 1, 3000));
  AssertTrue(WaitCount(FPublishCount, 1, 3000));
end;

{ --- reconexao --- }

procedure TPipePubSubTests.Resubscribe_AposReconexaoAutomatica;
var
  LName: string;
begin
  // O caso que dói: a assinatura vive na CONEXAO do lado do servidor, entao uma
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
  AssertTrue('primeira conexao nao confirmou', WaitCount(FCliConnCount, 1, 3000));
  FClients[0].Subscribe('caixa.#');
  AssertTrue(WaitSubscribers('caixa.3.status', 1, 3000));

  FServer.Stop;
  AssertTrue('queda nao notificada', WaitCount(FCliDiscCount, 1, 5000));
  FServer.Listen; // mesmo nome: o cliente reconecta
  AssertTrue('cliente nao reconectou', WaitCount(FCliConnCount, 2, 10000));

  // Nenhum Subscribe novo aqui: quem tem de reassinar e' a lib.
  AssertTrue('assinatura nao foi reenviada na reconexao',
    WaitSubscribers('caixa.3.status', 1, 5000));
  FServer.PublishText('caixa.3.status', 'depois da reconexao');
  AssertTrue('publicacao pos-reconexao nao chegou',
    WaitCount(FTopicCount[0], 1, 5000));
  AssertEquals(1, CountLog('0|caixa.3.status|depois da reconexao'));
  AssertEquals('o app nao devia ter de reassinar', 1,
    Length(FClients[0].Subscriptions));
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
  AssertTrue(WaitSubscribers('carga.x', 3, 3000));

  // Fanout para 3 assinantes, 300 vezes: o Stop tem de vencer a fila de
  // escritas em vez de esperar por ela (detector de deadlock).
  for I := 1 to 300 do
    FServer.PublishText('carga.x', 'p' + IntToStr(I));
  T0 := PipeTickMs;
  FServer.Stop;
  AssertTrue('Stop sob publicacao intensa demorou demais (deadlock?)',
    PipeTickMs - T0 < 2000);
  AssertFalse('servidor devia estar inativo', FServer.Active);
  AssertTrue('os clientes nao perceberam o Stop',
    WaitCount(FCliDiscCount, 3, 3000));
end;

initialization
  RegisterTest(TPipePubSubTests);

end.
