unit Pipes.StatsTests;

{ Testes de integracao das metricas/observabilidade (Pipes.Server.Stats/
  ConnectionStats, Pipes.Client.Stats): contadores de bytes/mensagens batem
  com o que foi de fato trocado, latencia de Request so' conta o caminho de
  SUCESSO (timeout fica de fora), e ConnectionStats devolve False para uma
  conexao que nao existe. Sempre ativos, sem opt-in, e validos em QUALQUER
  transporte — ao contrario do heartbeat, uso ptLocal aqui (mais simples,
  sem porta). Mestre DUnitX; o espelho FPCUnit em tests/Integration/fpc e'
  gerado por tools/gen_fpc_mirror.py. }

interface

uses
  DUnitX.TestFramework,
  Pipes.DUnitXCompat,
  SysUtils,
  Pipes.Types,
  PascalCommon.Threading,
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
  public
    [Test] procedure Servidor_Stats_ContaBytesEMensagens;
    [Test] procedure Cliente_Stats_ContaBytesEMensagens;
    [Test] procedure ConnectionStats_ConexaoInexistente_DevolveFalse;
    [Test] procedure Cliente_Stats_LatenciaSoContaSucesso;
    [Test] procedure SemCompressao_BytesWireIgualBytesLogicoNosDoisLados;
    [Test] procedure ComCompressao_BytesWireMenorQueBytesLogicoNosDoisLados;
  end;

implementation

var
  GNameSeq: Integer;

function UniquePipeName: string;
begin
  Result := 'pipes_faa_stats_' + IntToStr(Int64(PcTickMs)) + '_' +
    IntToStr(PcAtomicInc(GNameSeq));
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
  LDeadline := PcTickMs + ATimeoutMs;
  while (PcAtomicGet(ACounter) < AExpected) and (PcTickMs < LDeadline) do
    Sleep(5);
  Result := PcAtomicGet(ACounter) >= AExpected;
end;

procedure TPipeStatsTests.OnSrvMessage(Sender: TObject;
  AConnId: TPipeConnectionId; const AData: TBytes);
begin
  PcAtomicInc(FSrvMsgCount);
end;

procedure TPipeStatsTests.OnCliMessage(Sender: TObject;
  AConnId: TPipeConnectionId; const AData: TBytes);
begin
  PcAtomicInc(FCliMsgCount);
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
  TAssert.AssertTrue('servidor nao recebeu as N mensagens a tempo',
    WaitCount(FSrvMsgCount, N, 3000));

  LIds := FServer.ClientIds;
  TAssert.AssertEquals(1, Length(LIds));
  TAssert.AssertTrue('ConnectionStats devia achar a conexao estabelecida',
    FServer.ConnectionStats(LIds[0], LConnStats));
  TAssert.AssertTrue('MessagesReceived nao bate com o que foi enviado',
    LConnStats.MessagesReceived = UInt64(N));
  TAssert.AssertTrue('BytesReceived nao bate (header + payload por frame)',
    LConnStats.BytesReceived =
    UInt64(N * (PIPE_FRAME_HEADER_SIZE + PAYLOAD_LEN)));

  LSrvStats := FServer.Stats;
  TAssert.AssertEquals(1, LSrvStats.ClientCount);
  TAssert.AssertTrue('TotalConnectionsAccepted devia contar ao menos esta conexao',
    LSrvStats.TotalConnectionsAccepted >= 1);
  TAssert.AssertTrue('agregado do servidor nao reflete as mensagens recebidas',
    LSrvStats.TotalMessagesReceived >= UInt64(N));
  TAssert.AssertTrue(LSrvStats.PoolQueueDepth >= 0);
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
  TAssert.AssertTrue('servidor nao recebeu as N mensagens a tempo',
    WaitCount(FSrvMsgCount, N, 3000));

  for I := 1 to M do
    FServer.Broadcast(LPayload);
  TAssert.AssertTrue('cliente nao recebeu as M mensagens do broadcast a tempo',
    WaitCount(FCliMsgCount, M, 3000));

  LCliStats := FClient.Stats;
  TAssert.AssertTrue(LCliStats.MessagesSent = UInt64(N));
  TAssert.AssertTrue(LCliStats.BytesSent =
    UInt64(N * (PIPE_FRAME_HEADER_SIZE + PAYLOAD_LEN)));
  TAssert.AssertTrue(LCliStats.MessagesReceived = UInt64(M));
  TAssert.AssertTrue(LCliStats.BytesReceived =
    UInt64(M * (PIPE_FRAME_HEADER_SIZE + PAYLOAD_LEN)));
end;

procedure TPipeStatsTests.ConnectionStats_ConexaoInexistente_DevolveFalse;
var
  LStats: TPipeConnStats;
begin
  FServer := TPipeServer.Create(UniquePipeName);
  FServer.Listen;
  TAssert.AssertFalse('conexao inexistente devia devolver False',
    FServer.ConnectionStats(999999, LStats));
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
  TAssert.AssertException(EPipeTimeout, DoRequestComTimeoutCurto);
  LStats := FClient.Stats;
  TAssert.AssertEquals('timeout nao devia contar na latencia',
    Int64(0), Int64(LStats.AvgRequestLatencyMs));
  TAssert.AssertEquals('timeout nao devia contar na latencia',
    Int64(0), Int64(LStats.MaxRequestLatencyMs));
  TAssert.AssertEquals('nao devia sobrar request pendente apos o timeout',
    0, LStats.PendingRequests);

  // Um request BEM-SUCEDIDO deve contar.
  FServer.OnRequest := OnSrvRequestEco;
  FClient.Request(PipeUtf8Encode('oi'), 3000);
  LStats := FClient.Stats;
  TAssert.AssertTrue('latencia absurda', LStats.AvgRequestLatencyMs < 3000);
  TAssert.AssertTrue(LStats.MaxRequestLatencyMs >= LStats.AvgRequestLatencyMs);
  TAssert.AssertEquals(0, LStats.PendingRequests);
end;

procedure TPipeStatsTests.SemCompressao_BytesWireIgualBytesLogicoNosDoisLados;
const
  PAYLOAD_LEN = 200;
var
  LIds: TArray<TPipeConnectionId>;
  LConnStats: TPipeConnStats;
  LCliStats: TPipeClientStats;
  LPayload: TBytes;
begin
  // CompressionMinSize = 0 (padrao): o campo Wire tem que bater exatamente
  // com o logico, nos dois lados — transparencia total quando desligado.
  FServer := TPipeServer.Create(UniquePipeName);
  FServer.OnMessage := OnSrvMessage;
  FServer.Listen;
  FClient := TPipeClient.Create(FServer.Address);
  FClient.Connect(3000);

  SetLength(LPayload, PAYLOAD_LEN);
  FClient.SendBytes(LPayload);
  TAssert.AssertTrue('mensagem nao chegou a tempo', WaitCount(FSrvMsgCount, 1, 3000));

  LCliStats := FClient.Stats;
  TAssert.AssertTrue('sem compressao, BytesSentWire devia ser identico a BytesSent',
    LCliStats.BytesSentWire = LCliStats.BytesSent);

  LIds := FServer.ClientIds;
  TAssert.AssertEquals(1, Length(LIds));
  TAssert.AssertTrue(FServer.ConnectionStats(LIds[0], LConnStats));
  TAssert.AssertTrue('sem compressao, BytesReceivedWire devia ser identico a BytesReceived',
    LConnStats.BytesReceivedWire = LConnStats.BytesReceived);
end;

procedure TPipeStatsTests.ComCompressao_BytesWireMenorQueBytesLogicoNosDoisLados;
const
  PAYLOAD_LEN = 20000;
var
  LIds: TArray<TPipeConnectionId>;
  LConnStats: TPipeConnStats;
  LSrvStats: TPipeServerStats;
  LCliStats: TPipeClientStats;
  LPayload: TBytes;
begin
  // Payload grande e repetitivo (comprime bem) com CompressionMinSize ligado
  // so' no cliente: a decodificacao no servidor e' sempre ativa (ver
  // Pipes.Compression), entao nao precisa ligar dos dois lados para o
  // servidor enxergar a economia em BytesReceivedWire.
  FServer := TPipeServer.Create(UniquePipeName);
  FServer.OnMessage := OnSrvMessage;
  FServer.Listen;
  FClient := TPipeClient.Create(FServer.Address);
  FClient.CompressionMinSize := 256;
  FClient.Connect(3000);

  SetLength(LPayload, PAYLOAD_LEN);
  FillChar(LPayload[0], PAYLOAD_LEN, Ord('A'));
  FClient.SendBytes(LPayload);
  TAssert.AssertTrue('mensagem nao chegou a tempo', WaitCount(FSrvMsgCount, 1, 3000));

  LCliStats := FClient.Stats;
  TAssert.AssertTrue('BytesSentWire devia refletir a economia da compressao no envio',
    LCliStats.BytesSentWire < LCliStats.BytesSent);

  LIds := FServer.ClientIds;
  TAssert.AssertEquals(1, Length(LIds));
  TAssert.AssertTrue(FServer.ConnectionStats(LIds[0], LConnStats));
  TAssert.AssertTrue('BytesReceivedWire devia refletir a economia da compressao no recebimento',
    LConnStats.BytesReceivedWire < LConnStats.BytesReceived);

  LSrvStats := FServer.Stats;
  TAssert.AssertTrue('agregado do servidor tambem devia refletir a economia',
    LSrvStats.TotalBytesReceivedWire < LSrvStats.TotalBytesReceived);
end;

initialization
  TDUnitX.RegisterTestFixture(TPipeStatsTests);

end.
