unit Pipes.StatsTests;

{ Testes de integracao das metricas/observabilidade (Pipes.Server.Stats/
  ConnectionStats, Pipes.Client.Stats): contadores de bytes/mensagens batem
  com o que foi de fato trocado, latencia de Request so' conta o caminho de
  SUCESSO (timeout fica de fora), e ConnectionStats devolve False para uma
  conexao que nao existe. Sempre ativos, sem opt-in, e validos em QUALQUER
  transporte — ao contrario do heartbeat, uso ptLocal aqui (mais simples,
  sem porta). Versao DUnitX/Delphi; espelha a versao FPCUnit em
  tests/Integration/fpc. }

interface

uses
  DUnitX.TestFramework,
  SysUtils,
  Pipes.Types,
  Pipes.Threading,
  Pipes.Framing,
  Pipes.Server,
  Pipes.Client;

type
  [TestFixture]
  TPipeStatsTests = class
  private
    FServer: TPipeServer;
    FClient: TPipeClient;
    FSrvMsgCount: Integer; // atomico
    FCliMsgCount: Integer; // atomico
    procedure OnSrvMessage(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure OnCliMessage(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure OnSrvRequestEco(Sender: TObject; AConnId: TPipeConnectionId;
      const ARequest: TBytes; out AReply: TBytes);
    procedure OnSrvRequestLento(Sender: TObject; AConnId: TPipeConnectionId;
      const ARequest: TBytes; out AReply: TBytes);
    function WaitCount(var ACounter: Integer; AExpected: Integer;
      ATimeoutMs: Cardinal): Boolean;
    procedure DoRequestComTimeoutCurto;
  public
    [Setup] procedure SetUp;
    [TearDown] procedure TearDown;
  published
    [Test] procedure Servidor_Stats_ContaBytesEMensagens;
    [Test] procedure Cliente_Stats_ContaBytesEMensagens;
    [Test] procedure ConnectionStats_ConexaoInexistente_DevolveFalse;
    [Test] procedure Cliente_Stats_LatenciaSoContaSucesso;
  end;

implementation

// Comparacao nao-generica (evita E2532: Length() e' NativeInt no Win64 e o
// AreEqual<T> generico do DUnitX nao infere T com argumentos de tipos
// diferentes — ver Pipes.FramingTests/Pipes.EndToEndTests).
procedure EqualInt(AExpected, AActual: Integer);
begin
  Assert.AreEqual(AExpected, AActual);
end;

var
  GNameSeq: Integer;

function UniquePipeName: string;
begin
  Result := 'pipes_faa_stats_' + IntToStr(Int64(PipeTickMs)) + '_' +
    IntToStr(PipeAtomicInc(GNameSeq));
end;

{ TPipeStatsTests }

procedure TPipeStatsTests.SetUp;
begin
  // Mesma licao do fixture compartilhado do DUnitX (ver Pipes.HeartbeatTests):
  // sem isto, um teste anterior deixaria os contadores sujos para o proximo.
  FSrvMsgCount := 0;
  FCliMsgCount := 0;
end;

procedure TPipeStatsTests.TearDown;
begin
  FreeAndNil(FClient); // Disconnect no destructor
  FreeAndNil(FServer); // Stop no destructor
end;

function TPipeStatsTests.WaitCount(var ACounter: Integer; AExpected: Integer;
  ATimeoutMs: Cardinal): Boolean;
var
  LDeadline: UInt64;
begin
  LDeadline := PipeTickMs + ATimeoutMs;
  while (PipeAtomicGet(ACounter) < AExpected) and (PipeTickMs < LDeadline) do
    Sleep(5);
  Result := PipeAtomicGet(ACounter) >= AExpected;
end;

procedure TPipeStatsTests.OnSrvMessage(Sender: TObject;
  AConnId: TPipeConnectionId; const AData: TBytes);
begin
  PipeAtomicInc(FSrvMsgCount);
end;

procedure TPipeStatsTests.OnCliMessage(Sender: TObject;
  AConnId: TPipeConnectionId; const AData: TBytes);
begin
  PipeAtomicInc(FCliMsgCount);
end;

procedure TPipeStatsTests.OnSrvRequestEco(Sender: TObject;
  AConnId: TPipeConnectionId; const ARequest: TBytes; out AReply: TBytes);
begin
  AReply := ARequest;
end;

procedure TPipeStatsTests.OnSrvRequestLento(Sender: TObject;
  AConnId: TPipeConnectionId; const ARequest: TBytes; out AReply: TBytes);
begin
  Sleep(800); // maior que o timeout do teste (200ms)
  AReply := ARequest;
end;

procedure TPipeStatsTests.DoRequestComTimeoutCurto;
begin
  FClient.Request(PipeUtf8Encode('oi'), 200);
end;

procedure TPipeStatsTests.Servidor_Stats_ContaBytesEMensagens;
const
  N = 5;
  PAYLOAD_LEN = 10;
var
  LIds: TArray<TPipeConnectionId>;
  LConnStats: TPipeConnStats;
  LSrvStats: TPipeServerStats;
  LPayload: TBytes;
  I: Integer;
begin
  FServer := TPipeServer.Create(UniquePipeName);
  FServer.OnMessage := OnSrvMessage;
  FServer.Listen;
  FClient := TPipeClient.Create(FServer.Address);
  FClient.Connect(3000);

  SetLength(LPayload, PAYLOAD_LEN);
  for I := 0 to PAYLOAD_LEN - 1 do
    LPayload[I] := I;
  for I := 1 to N do
    FClient.SendBytes(LPayload);
  Assert.IsTrue(WaitCount(FSrvMsgCount, N, 3000),
    'servidor nao recebeu as N mensagens a tempo');

  LIds := FServer.ClientIds;
  EqualInt(1, Length(LIds));
  Assert.IsTrue(FServer.ConnectionStats(LIds[0], LConnStats),
    'ConnectionStats devia achar a conexao estabelecida');
  Assert.IsTrue(LConnStats.MessagesReceived = UInt64(N),
    'MessagesReceived nao bate com o que foi enviado');
  Assert.IsTrue(LConnStats.BytesReceived =
    UInt64(N * (PIPE_FRAME_HEADER_SIZE + PAYLOAD_LEN)),
    'BytesReceived nao bate (header + payload por frame)');

  LSrvStats := FServer.Stats;
  Assert.AreEqual(1, LSrvStats.ClientCount);
  Assert.IsTrue(LSrvStats.TotalConnectionsAccepted >= 1,
    'TotalConnectionsAccepted devia contar ao menos esta conexao');
  Assert.IsTrue(LSrvStats.TotalMessagesReceived >= UInt64(N),
    'agregado do servidor nao reflete as mensagens recebidas');
  Assert.IsTrue(LSrvStats.PoolQueueDepth >= 0);
end;

procedure TPipeStatsTests.Cliente_Stats_ContaBytesEMensagens;
const
  N = 4;
  M = 3;
  PAYLOAD_LEN = 8;
var
  LCliStats: TPipeClientStats;
  LPayload: TBytes;
  I: Integer;
begin
  FServer := TPipeServer.Create(UniquePipeName);
  FServer.OnMessage := OnSrvMessage;
  FServer.Listen;
  FClient := TPipeClient.Create(FServer.Address);
  FClient.OnMessage := OnCliMessage;
  FClient.Connect(3000);

  SetLength(LPayload, PAYLOAD_LEN);
  for I := 1 to N do
    FClient.SendBytes(LPayload);
  Assert.IsTrue(WaitCount(FSrvMsgCount, N, 3000),
    'servidor nao recebeu as N mensagens a tempo');

  for I := 1 to M do
    FServer.Broadcast(LPayload);
  Assert.IsTrue(WaitCount(FCliMsgCount, M, 3000),
    'cliente nao recebeu as M mensagens do broadcast a tempo');

  LCliStats := FClient.Stats;
  Assert.IsTrue(LCliStats.MessagesSent = UInt64(N));
  Assert.IsTrue(LCliStats.BytesSent =
    UInt64(N * (PIPE_FRAME_HEADER_SIZE + PAYLOAD_LEN)));
  Assert.IsTrue(LCliStats.MessagesReceived = UInt64(M));
  Assert.IsTrue(LCliStats.BytesReceived =
    UInt64(M * (PIPE_FRAME_HEADER_SIZE + PAYLOAD_LEN)));
end;

procedure TPipeStatsTests.ConnectionStats_ConexaoInexistente_DevolveFalse;
var
  LStats: TPipeConnStats;
begin
  FServer := TPipeServer.Create(UniquePipeName);
  FServer.Listen;
  Assert.IsFalse(FServer.ConnectionStats(999999, LStats),
    'conexao inexistente devia devolver False');
end;

procedure TPipeStatsTests.Cliente_Stats_LatenciaSoContaSucesso;
var
  LStats: TPipeClientStats;
begin
  FServer := TPipeServer.Create(UniquePipeName);
  FServer.OnRequest := OnSrvRequestLento;
  FServer.Listen;
  FClient := TPipeClient.Create(FServer.Address);
  FClient.Connect(3000);

  // Timeout NAO deve contar na latencia (a resposta tardia do handler lento
  // chega depois, mas o slot ja foi removido — ver TPipeClient.Request).
  Assert.WillRaise(DoRequestComTimeoutCurto, EPipeTimeout);
  LStats := FClient.Stats;
  Assert.AreEqual(Cardinal(0), LStats.AvgRequestLatencyMs,
    'timeout nao devia contar na latencia');
  Assert.AreEqual(Cardinal(0), LStats.MaxRequestLatencyMs,
    'timeout nao devia contar na latencia');
  Assert.AreEqual(0, LStats.PendingRequests,
    'nao devia sobrar request pendente apos o timeout');

  // Um request BEM-SUCEDIDO deve contar.
  FServer.OnRequest := OnSrvRequestEco;
  FClient.Request(PipeUtf8Encode('oi'), 3000);
  LStats := FClient.Stats;
  Assert.IsTrue(LStats.AvgRequestLatencyMs < 3000, 'latencia absurda');
  Assert.IsTrue(LStats.MaxRequestLatencyMs >= LStats.AvgRequestLatencyMs);
  Assert.AreEqual(0, LStats.PendingRequests);
end;

initialization
  TDUnitX.RegisterTestFixture(TPipeStatsTests);

end.
