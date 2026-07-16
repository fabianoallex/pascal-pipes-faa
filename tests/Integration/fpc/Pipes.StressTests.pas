unit Pipes.StressTests;

{$mode delphi}{$H+}

{ Testes de stress do milestone M7: Stop sob trafego intenso (detector de
  deadlock), quedas abruptas repetidas sem vazamento de handle/fd, requests
  concorrentes (correlacao RPC sob disputa), ciclos de reuso de servidor e
  cliente e integridade de payload grande. Versao FPCUnit; espelha a versao
  DUnitX em tests/Integration. }

interface

uses
  fpcunit, testregistry,
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

  TPipeStressTests = class(TTestCase)
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
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure StopSobTrafegoIntenso_TerminaEm2s;
    procedure QuedaAbruptaRepetida_EventosSemVazarHandleFd;
    procedure RequestsConcorrentes_CorrelacaoSemTroca;
    procedure CiclosListenStop_ServidorReutilizavel;
    procedure CiclosConnectDisconnect_ClienteReutilizavel;
    procedure PayloadGrande_RoundTripIntegro;
  end;

implementation

var
  GNameSeq: Integer;

function UniquePipeName: string;
begin
  Result := 'pipes_faa_stress_' + IntToStr(Int64(PipeTickMs)) + '_' +
    IntToStr(PipeAtomicInc(GNameSeq));
end;

// --- contagem de handles/fds do processo (detector de vazamento) ------------

{$IFDEF UNIX}
function CurrentHandleCount: Integer;
var
  LSr: TSearchRec;
begin
  Result := 0;
  if FindFirst('/proc/self/fd/*', faAnyFile, LSr) = 0 then
  begin
    repeat
      Inc(Result);
    until FindNext(LSr) <> 0;
    FindClose(LSr);
  end;
end;
{$ELSE}
// Declarada localmente: nem toda versao da unit Windows do FPC a expoe.
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
{$ENDIF}

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

procedure TPipeStressTests.SetUp;
begin
  inherited;
  FSrvMsgCount := 0;
  FSrvConnCount := 0;
  FSrvDiscCount := 0;
end;

procedure TPipeStressTests.TearDown;
begin
  FreeAndNil(FServer); // Stop no destructor
  inherited;
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
    AssertTrue('conexao nao foi aceita pelo servidor',
      WaitCount(FSrvConnCount, AExpectedConns, 5000));
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
    AssertTrue('flood nao gerou trafego suficiente',
      WaitCount(FSrvMsgCount, 200, 5000));

    T0 := PipeTickMs;
    FServer.Stop;
    AssertTrue('Stop sob flood de 4 clientes demorou demais (deadlock?)',
      PipeTickMs - T0 < 2000);
    AssertTrue('servidor devia estar inativo', not FServer.Active);
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
  AssertTrue('warmup: OnClientDisconnected nao disparou',
    WaitCount(FSrvDiscCount, 1, 5000));
  Sleep(100); // cleanup do ciclo de aquecimento assenta
  LBaseline := CurrentHandleCount;

  for I := 1 to CYCLES do
    AbruptClientCycle(1 + I);
  AssertTrue('nem toda queda abrupta gerou OnClientDisconnected',
    WaitCount(FSrvDiscCount, 1 + CYCLES, 10000));
  AssertTrue('mensagens pre-queda deviam ter chegado',
    WaitCount(FSrvMsgCount, 1 + CYCLES, 5000));

  // Espera o teardown assíncrono devolver os handles/fds ao patamar base.
  LDeadline := PipeTickMs + 5000;
  LFinal := CurrentHandleCount;
  while (LFinal > LBaseline + SLACK) and (PipeTickMs < LDeadline) do
  begin
    Sleep(50);
    LFinal := CurrentHandleCount;
  end;
  AssertTrue(Format('vazamento de handle/fd: base=%d, final=%d apos %d quedas',
    [LBaseline, LFinal, CYCLES]), LFinal <= LBaseline + SLACK);
  AssertEquals(0, FServer.ClientCount);
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
    AssertEquals('requests concluidos', THREADS * REQS, LCompleted);
    AssertEquals('replies trocados/falhos (correlacao)', 0, LFailures);
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
    AssertTrue('ciclo ' + IntToStr(LCycle) + ': servidor devia estar ativo',
      FServer.Active);
    LClient := TNamedPipeClient.Create(FServer.PipeName);
    try
      LClient.Connect(3000);
      LClient.SendText('ciclo' + IntToStr(LCycle));
      AssertTrue('ciclo ' + IntToStr(LCycle) + ': mensagem nao chegou',
        WaitCount(FSrvMsgCount, LCycle, 5000));
    finally
      LClient.Free;
    end;
    T0 := PipeTickMs;
    FServer.Stop;
    AssertTrue('ciclo ' + IntToStr(LCycle) + ': Stop lento (deadlock?)',
      PipeTickMs - T0 < 2000);
  end;
  AssertEquals(CYCLES, PipeAtomicGet(FSrvMsgCount));
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
      AssertTrue('ciclo ' + IntToStr(LCycle) + ': mensagem nao chegou',
        WaitCount(FSrvMsgCount, LCycle, 5000));
      LClient.Disconnect;
      AssertTrue('ciclo ' + IntToStr(LCycle) + ': desconexao nao notificada',
        WaitCount(FSrvDiscCount, LCycle, 5000));
    end;
  finally
    LClient.Free;
  end;
  AssertEquals(CYCLES, PipeAtomicGet(FSrvConnCount));
  AssertEquals(0, FServer.ClientCount);
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
    AssertEquals('tamanho do eco', PAYLOAD_SIZE, Length(LReply));
    AssertTrue('payload corrompido no round-trip',
      CompareMem(@LData[0], @LReply[0], PAYLOAD_SIZE));
  finally
    LClient.Free;
  end;
end;

initialization
  RegisterTest(TPipeStressTests);

end.
