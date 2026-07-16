unit Pipes.StressTests;

{ Testes de stress do milestone M7: Stop sob trafego intenso (detector de
  deadlock), quedas abruptas repetidas sem vazamento de handle/fd, requests
  concorrentes (correlacao RPC sob disputa), ciclos de reuso de servidor e
  cliente e integridade de payload grande. Versao DUnitX/Delphi (Win64); a
  versao FPCUnit em tests/Integration/fpc espelha a mesma cobertura. }

interface

uses
  DUnitX.TestFramework,
  SysUtils,
  Classes,
  Pipes.Types,
  Pipes.Threading,
  Pipes.Framing,
  Pipes.Transport,
  Pipes.Server,
  Pipes.Client;

type
  { Envia payloads em loop apertado ate Terminate ou queda da conexao. }
  TFloodSender = class(TThread)
  private
    FClient: TNamedPipeClient;
    FSent: Integer; // atomico
  protected
    procedure Execute; override;
  public
    constructor Create(AClient: TNamedPipeClient);
    property Sent: Integer read FSent;
  end;

  { Dispara N requests sequenciais e confere cada reply contra o que enviou
    (correlacao). Mismatches/excecoes viram FFailures; ler apos o WaitFor. }
  TRequestStorm = class(TThread)
  private
    FClient: TNamedPipeClient;
    FPrefix: string;
    FCount: Integer;
    FFailures: Integer;
    FCompleted: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(AClient: TNamedPipeClient; const APrefix: string;
      ACount: Integer);
    property Failures: Integer read FFailures;
    property Completed: Integer read FCompleted;
  end;

  [TestFixture]
  TPipeStressTests = class
  private
    FServer: TNamedPipeServer;
    FSrvMsgCount: Integer;  // atomicos
    FSrvConnCount: Integer;
    FSrvDiscCount: Integer;
    procedure OnSrvMessage(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure OnSrvClientConnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnSrvClientDisconnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnSrvRequestEcoTexto(Sender: TObject; AConnId: TPipeConnectionId;
      const ARequest: TBytes; out AReply: TBytes);
    procedure OnSrvRequestEcoBytes(Sender: TObject; AConnId: TPipeConnectionId;
      const ARequest: TBytes; out AReply: TBytes);
    procedure OpenServer;
    function WaitCount(var ACounter: Integer; AExpected: Integer;
      ATimeoutMs: Cardinal): Boolean;
    // Conecta um endpoint cru, espera o servidor ACEITAR (um cliente que
    // morre antes do accept e' invisivel por design — o listener recicla a
    // instancia), envia 1 frame e morre sem despedida.
    procedure AbruptClientCycle(AExpectedConns: Integer);
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;
  published
    [Test] procedure StopSobTrafegoIntenso_TerminaEm2s;
    [Test] procedure QuedaAbruptaRepetida_EventosSemVazarHandleFd;
    [Test] procedure RequestsConcorrentes_CorrelacaoSemTroca;
    [Test] procedure CiclosListenStop_ServidorReutilizavel;
    [Test] procedure CiclosConnectDisconnect_ClienteReutilizavel;
    [Test] procedure PayloadGrande_RoundTripIntegro;
  end;

implementation

var
  GNameSeq: Integer;

function UniquePipeName: string;
begin
  Result := 'pipes_faa_stress_' + IntToStr(Int64(PipeTickMs)) + '_' +
    IntToStr(PipeAtomicInc(GNameSeq));
end;

// Compara contagens como Integer (evita E2532 do AreEqual<T> generico).
procedure EqualInt(AExpected, AActual: Integer; const AMsg: string = '');
begin
  Assert.AreEqual(AExpected, AActual, AMsg);
end;

// --- contagem de handles do processo (detector de vazamento) ----------------

// Declaradas localmente para nao depender da versao da Winapi.Windows.
function GetProcessHandleCount(hProcess: THandle;
  var pdwHandleCount: LongWord): LongBool; stdcall;
  external 'kernel32.dll' name 'GetProcessHandleCount';
function GetCurrentProcess: THandle; stdcall;
  external 'kernel32.dll' name 'GetCurrentProcess';

function CurrentHandleCount: Integer;
var
  LCnt: LongWord;
begin
  LCnt := 0;
  GetProcessHandleCount(GetCurrentProcess, LCnt);
  Result := Integer(LCnt);
end;

{ TFloodSender }

constructor TFloodSender.Create(AClient: TNamedPipeClient);
begin
  FClient := AClient;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TFloodSender.Execute;
var
  LPayload: TBytes;
  I: Integer;
begin
  SetLength(LPayload, 512);
  for I := 0 to High(LPayload) do
    LPayload[I] := Byte(I);
  while not Terminated do
  begin
    try
      FClient.SendBytes(LPayload);
    except
      on EPipeError do
        Break; // servidor parou no meio do flood: fim esperado
    end;
    PipeAtomicInc(FSent);
  end;
end;

{ TRequestStorm }

constructor TRequestStorm.Create(AClient: TNamedPipeClient;
  const APrefix: string; ACount: Integer);
begin
  FClient := AClient;
  FPrefix := APrefix;
  FCount := ACount;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TRequestStorm.Execute;
var
  I: Integer;
  LSent, LReply: string;
begin
  for I := 1 to FCount do
  begin
    LSent := FPrefix + IntToStr(I);
    try
      LReply := FClient.RequestText(LSent, 15000);
      if LReply <> 'eco:' + LSent then
        Inc(FFailures); // reply de OUTRO request = correlacao quebrada
      Inc(FCompleted);
    except
      Inc(FFailures);
    end;
  end;
end;

{ TPipeStressTests }

procedure TPipeStressTests.Setup;
begin
  FSrvMsgCount := 0;
  FSrvConnCount := 0;
  FSrvDiscCount := 0;
end;

procedure TPipeStressTests.TearDown;
begin
  FreeAndNil(FServer); // Stop no destructor
end;

function TPipeStressTests.WaitCount(var ACounter: Integer;
  AExpected: Integer; ATimeoutMs: Cardinal): Boolean;
var
  LDeadline: UInt64;
begin
  LDeadline := PipeTickMs + ATimeoutMs;
  while (PipeAtomicGet(ACounter) < AExpected) and (PipeTickMs < LDeadline) do
    Sleep(5);
  Result := PipeAtomicGet(ACounter) >= AExpected;
end;

procedure TPipeStressTests.OnSrvMessage(Sender: TObject;
  AConnId: TPipeConnectionId; const AData: TBytes);
begin
  PipeAtomicInc(FSrvMsgCount);
end;

procedure TPipeStressTests.OnSrvClientConnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  PipeAtomicInc(FSrvConnCount);
end;

procedure TPipeStressTests.OnSrvClientDisconnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  PipeAtomicInc(FSrvDiscCount);
end;

procedure TPipeStressTests.OnSrvRequestEcoTexto(Sender: TObject;
  AConnId: TPipeConnectionId; const ARequest: TBytes; out AReply: TBytes);
begin
  AReply := PipeUtf8Encode('eco:' + PipeUtf8Decode(ARequest));
end;

procedure TPipeStressTests.OnSrvRequestEcoBytes(Sender: TObject;
  AConnId: TPipeConnectionId; const ARequest: TBytes; out AReply: TBytes);
begin
  AReply := Copy(ARequest, 0, Length(ARequest));
end;

procedure TPipeStressTests.OpenServer;
begin
  FServer := TNamedPipeServer.Create(UniquePipeName);
  FServer.OnMessage := OnSrvMessage;
  FServer.OnClientConnected := OnSrvClientConnected;
  FServer.OnClientDisconnected := OnSrvClientDisconnected;
  FServer.Listen;
end;

procedure TPipeStressTests.AbruptClientCycle(AExpectedConns: Integer);
var
  LEp: TPipeEndpoint;
  LStream: TStream;
begin
  LEp := PipeConnect(FServer.PipeName, 3000);
  try
    Assert.IsTrue(WaitCount(FSrvConnCount, AExpectedConns, 5000),
      'conexao nao foi aceita pelo servidor');
    LStream := TPipeEndpointStream.Create(LEp);
    try
      PipeWriteFrame(LStream, TPipeFrame.Msg(PipeUtf8Encode('boom')),
        PIPES_DEFAULT_MAX_MESSAGE_SIZE);
    finally
      LStream.Free;
    end;
  finally
    LEp.Free; // sem despedida: do ponto de vista do servidor, o cliente caiu
  end;
end;

procedure TPipeStressTests.StopSobTrafegoIntenso_TerminaEm2s;
var
  LClients: array[0..3] of TNamedPipeClient;
  LSenders: array[0..3] of TFloodSender;
  I: Integer;
  T0: UInt64;
begin
  OpenServer;
  for I := 0 to 3 do
  begin
    LClients[I] := nil;
    LSenders[I] := nil;
  end;
  try
    for I := 0 to 3 do
    begin
      LClients[I] := TNamedPipeClient.Create(FServer.PipeName);
      LClients[I].Connect(3000);
    end;
    for I := 0 to 3 do
      LSenders[I] := TFloodSender.Create(LClients[I]);
    // Garante trafego REAL em voo antes do Stop.
    Assert.IsTrue(WaitCount(FSrvMsgCount, 200, 5000),
      'flood nao gerou trafego suficiente');

    T0 := PipeTickMs;
    FServer.Stop;
    Assert.IsTrue(PipeTickMs - T0 < 2000,
      'Stop sob flood de 4 clientes demorou demais (deadlock?)');
    Assert.IsFalse(FServer.Active, 'servidor devia estar inativo');
  finally
    for I := 0 to 3 do
      if LSenders[I] <> nil then
      begin
        LSenders[I].Terminate;
        LSenders[I].WaitFor;
        LSenders[I].Free;
      end;
    for I := 0 to 3 do
      LClients[I].Free;
  end;
end;

procedure TPipeStressTests.QuedaAbruptaRepetida_EventosSemVazarHandleFd;
const
  CYCLES = 15;
  SLACK = 10; // folga p/ ruido do RTL; um vazamento real custa >= 4 por ciclo
var
  I, LBaseline, LFinal: Integer;
  LDeadline: UInt64;
begin
  OpenServer;
  // Aquecimento: primeiro ciclo cria pool global, threads e caches do RTL.
  AbruptClientCycle(1);
  Assert.IsTrue(WaitCount(FSrvDiscCount, 1, 5000),
    'warmup: OnClientDisconnected nao disparou');
  Sleep(100); // cleanup do ciclo de aquecimento assenta
  LBaseline := CurrentHandleCount;

  for I := 1 to CYCLES do
    AbruptClientCycle(1 + I);
  Assert.IsTrue(WaitCount(FSrvDiscCount, 1 + CYCLES, 10000),
    'nem toda queda abrupta gerou OnClientDisconnected');
  Assert.IsTrue(WaitCount(FSrvMsgCount, 1 + CYCLES, 5000),
    'mensagens pre-queda deviam ter chegado');

  // Espera o teardown assíncrono devolver os handles ao patamar base.
  LDeadline := PipeTickMs + 5000;
  LFinal := CurrentHandleCount;
  while (LFinal > LBaseline + SLACK) and (PipeTickMs < LDeadline) do
  begin
    Sleep(50);
    LFinal := CurrentHandleCount;
  end;
  Assert.IsTrue(LFinal <= LBaseline + SLACK,
    Format('vazamento de handle: base=%d, final=%d apos %d quedas',
      [LBaseline, LFinal, CYCLES]));
  EqualInt(0, FServer.ClientCount);
end;

procedure TPipeStressTests.RequestsConcorrentes_CorrelacaoSemTroca;
const
  THREADS = 6;
  REQS = 30;
var
  LClient: TNamedPipeClient;
  LStorms: array[0..THREADS - 1] of TRequestStorm;
  I, LFailures, LCompleted: Integer;
begin
  OpenServer;
  FServer.OnRequest := OnSrvRequestEcoTexto;
  for I := 0 to THREADS - 1 do
    LStorms[I] := nil;
  LClient := TNamedPipeClient.Create(FServer.PipeName);
  try
    LClient.Connect(3000);
    for I := 0 to THREADS - 1 do
      LStorms[I] := TRequestStorm.Create(LClient, 't' + IntToStr(I) + ':', REQS);
    LFailures := 0;
    LCompleted := 0;
    for I := 0 to THREADS - 1 do
    begin
      LStorms[I].WaitFor;
      Inc(LFailures, LStorms[I].Failures);
      Inc(LCompleted, LStorms[I].Completed);
    end;
    EqualInt(THREADS * REQS, LCompleted, 'requests concluidos');
    EqualInt(0, LFailures, 'replies trocados/falhos (correlacao)');
  finally
    for I := 0 to THREADS - 1 do
      LStorms[I].Free;
    LClient.Free;
  end;
end;

procedure TPipeStressTests.CiclosListenStop_ServidorReutilizavel;
const
  CYCLES = 8;
var
  LClient: TNamedPipeClient;
  LCycle: Integer;
  T0: UInt64;
begin
  OpenServer;
  FServer.Stop; // comeca cada ciclo do estado parado
  for LCycle := 1 to CYCLES do
  begin
    FServer.Listen;
    Assert.IsTrue(FServer.Active,
      'ciclo ' + IntToStr(LCycle) + ': servidor devia estar ativo');
    LClient := TNamedPipeClient.Create(FServer.PipeName);
    try
      LClient.Connect(3000);
      LClient.SendText('ciclo' + IntToStr(LCycle));
      Assert.IsTrue(WaitCount(FSrvMsgCount, LCycle, 5000),
        'ciclo ' + IntToStr(LCycle) + ': mensagem nao chegou');
    finally
      LClient.Free;
    end;
    T0 := PipeTickMs;
    FServer.Stop;
    Assert.IsTrue(PipeTickMs - T0 < 2000,
      'ciclo ' + IntToStr(LCycle) + ': Stop lento (deadlock?)');
  end;
  EqualInt(CYCLES, PipeAtomicGet(FSrvMsgCount));
end;

procedure TPipeStressTests.CiclosConnectDisconnect_ClienteReutilizavel;
const
  CYCLES = 10;
var
  LClient: TNamedPipeClient;
  LCycle: Integer;
begin
  OpenServer;
  LClient := TNamedPipeClient.Create(FServer.PipeName);
  try
    for LCycle := 1 to CYCLES do
    begin
      LClient.Connect(3000);
      LClient.SendText('volta' + IntToStr(LCycle));
      Assert.IsTrue(WaitCount(FSrvMsgCount, LCycle, 5000),
        'ciclo ' + IntToStr(LCycle) + ': mensagem nao chegou');
      LClient.Disconnect;
      Assert.IsTrue(WaitCount(FSrvDiscCount, LCycle, 5000),
        'ciclo ' + IntToStr(LCycle) + ': desconexao nao notificada');
    end;
  finally
    LClient.Free;
  end;
  EqualInt(CYCLES, PipeAtomicGet(FSrvConnCount));
  EqualInt(0, FServer.ClientCount);
end;

procedure TPipeStressTests.PayloadGrande_RoundTripIntegro;
const
  PAYLOAD_SIZE = 2 * 1024 * 1024; // 2 MB: força chunking pelos buffers de 64 KB
var
  LClient: TNamedPipeClient;
  LData, LReply: TBytes;
  I: Integer;
begin
  OpenServer;
  FServer.OnRequest := OnSrvRequestEcoBytes;
  LData := nil;
  SetLength(LData, PAYLOAD_SIZE);
  for I := 0 to High(LData) do
    LData[I] := Byte((I * 31 + 7) and $FF);
  LClient := TNamedPipeClient.Create(FServer.PipeName);
  try
    LClient.Connect(3000);
    LReply := LClient.Request(LData, 15000);
    EqualInt(PAYLOAD_SIZE, Length(LReply), 'tamanho do eco');
    Assert.IsTrue(CompareMem(@LData[0], @LReply[0], PAYLOAD_SIZE),
      'payload corrompido no round-trip');
  finally
    LClient.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TPipeStressTests);

end.
