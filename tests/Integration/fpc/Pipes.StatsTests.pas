unit Pipes.StatsTests;

{$mode delphi}{$H+}

{ Testes de integracao das metricas/observabilidade (Pipes.Server.Stats/
  ConnectionStats, Pipes.Client.Stats): contadores de bytes/mensagens batem
  com o que foi de fato trocado, latencia de Request so' conta o caminho de
  SUCESSO (timeout fica de fora), e ConnectionStats devolve False para uma
  conexao que nao existe. Sempre ativos, sem opt-in, e validos em QUALQUER
  transporte — ao contrario do heartbeat, uso ptLocal aqui (mais simples,
  sem porta). Versao FPCUnit; espelha a versao DUnitX em tests/Integration. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  Pipes.Types,
  Pipes.Threading,
  Pipes.Framing,
  Pipes.Server,
  Pipes.Client;

type
  TPipeStatsTests = class(TTestCase)
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
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure Servidor_Stats_ContaBytesEMensagens;
    procedure Cliente_Stats_ContaBytesEMensagens;
    procedure ConnectionStats_ConexaoInexistente_DevolveFalse;
    procedure Cliente_Stats_LatenciaSoContaSucesso;
    procedure SemCompressao_BytesWireIgualBytesLogicoNosDoisLados;
    procedure ComCompressao_BytesWireMenorQueBytesLogicoNosDoisLados;
  end;

implementation

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
  inherited;
  FSrvMsgCount := 0;
  FCliMsgCount := 0;
end;

procedure TPipeStatsTests.TearDown;
begin
  FreeAndNil(FClient); // Disconnect no destructor
  FreeAndNil(FServer); // Stop no destructor
  inherited;
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
  AssertTrue('servidor nao recebeu as N mensagens a tempo',
    WaitCount(FSrvMsgCount, N, 3000));

  LIds := FServer.ClientIds;
  AssertEquals(1, Length(LIds));
  AssertTrue('ConnectionStats devia achar a conexao estabelecida',
    FServer.ConnectionStats(LIds[0], LConnStats));
  AssertTrue('MessagesReceived nao bate com o que foi enviado',
    LConnStats.MessagesReceived = UInt64(N));
  AssertTrue('BytesReceived nao bate (header + payload por frame)',
    LConnStats.BytesReceived =
      UInt64(N * (PIPE_FRAME_HEADER_SIZE + PAYLOAD_LEN)));

  LSrvStats := FServer.Stats;
  AssertEquals(1, LSrvStats.ClientCount);
  AssertTrue('TotalConnectionsAccepted devia contar ao menos esta conexao',
    LSrvStats.TotalConnectionsAccepted >= 1);
  AssertTrue('agregado do servidor nao reflete as mensagens recebidas',
    LSrvStats.TotalMessagesReceived >= UInt64(N));
  AssertTrue(LSrvStats.PoolQueueDepth >= 0);
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
  AssertTrue('servidor nao recebeu as N mensagens a tempo',
    WaitCount(FSrvMsgCount, N, 3000));

  for I := 1 to M do
    FServer.Broadcast(LPayload);
  AssertTrue('cliente nao recebeu as M mensagens do broadcast a tempo',
    WaitCount(FCliMsgCount, M, 3000));

  LCliStats := FClient.Stats;
  AssertTrue(LCliStats.MessagesSent = UInt64(N));
  AssertTrue(LCliStats.BytesSent =
    UInt64(N * (PIPE_FRAME_HEADER_SIZE + PAYLOAD_LEN)));
  AssertTrue(LCliStats.MessagesReceived = UInt64(M));
  AssertTrue(LCliStats.BytesReceived =
    UInt64(M * (PIPE_FRAME_HEADER_SIZE + PAYLOAD_LEN)));
end;

procedure TPipeStatsTests.ConnectionStats_ConexaoInexistente_DevolveFalse;
var
  LStats: TPipeConnStats;
begin
  FServer := TPipeServer.Create(UniquePipeName);
  FServer.Listen;
  AssertFalse('conexao inexistente devia devolver False',
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
  AssertException(EPipeTimeout, DoRequestComTimeoutCurto);
  LStats := FClient.Stats;
  AssertEquals('timeout nao devia contar na latencia',
    0, Integer(LStats.AvgRequestLatencyMs));
  AssertEquals('timeout nao devia contar na latencia',
    0, Integer(LStats.MaxRequestLatencyMs));
  AssertEquals('nao devia sobrar request pendente apos o timeout',
    0, LStats.PendingRequests);

  // Um request BEM-SUCEDIDO deve contar.
  FServer.OnRequest := OnSrvRequestEco;
  FClient.Request(PipeUtf8Encode('oi'), 3000);
  LStats := FClient.Stats;
  AssertTrue('latencia absurda', LStats.AvgRequestLatencyMs < 3000);
  AssertTrue(LStats.MaxRequestLatencyMs >= LStats.AvgRequestLatencyMs);
  AssertEquals(0, LStats.PendingRequests);
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
  AssertTrue('mensagem nao chegou a tempo', WaitCount(FSrvMsgCount, 1, 3000));

  LCliStats := FClient.Stats;
  AssertTrue('sem compressao, BytesSentWire devia ser identico a BytesSent',
    LCliStats.BytesSentWire = LCliStats.BytesSent);

  LIds := FServer.ClientIds;
  AssertEquals(1, Length(LIds));
  AssertTrue(FServer.ConnectionStats(LIds[0], LConnStats));
  AssertTrue('sem compressao, BytesReceivedWire devia ser identico a BytesReceived',
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
  AssertTrue('mensagem nao chegou a tempo', WaitCount(FSrvMsgCount, 1, 3000));

  LCliStats := FClient.Stats;
  AssertTrue('BytesSentWire devia refletir a economia da compressao no envio',
    LCliStats.BytesSentWire < LCliStats.BytesSent);

  LIds := FServer.ClientIds;
  AssertEquals(1, Length(LIds));
  AssertTrue(FServer.ConnectionStats(LIds[0], LConnStats));
  AssertTrue(
    'BytesReceivedWire devia refletir a economia da compressao no recebimento',
    LConnStats.BytesReceivedWire < LConnStats.BytesReceived);

  LSrvStats := FServer.Stats;
  AssertTrue('agregado do servidor tambem devia refletir a economia',
    LSrvStats.TotalBytesReceivedWire < LSrvStats.TotalBytesReceived);
end;

initialization
  RegisterTest(TPipeStatsTests);

end.
