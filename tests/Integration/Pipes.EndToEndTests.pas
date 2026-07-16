unit Pipes.EndToEndTests;

{ Testes fim-a-fim da camada de alto nivel (TNamedPipeServer/TNamedPipeClient):
  mensagens nos dois sentidos, eventos de conexao/desconexao, ordem com
  pdmSerialized, multiplos clientes e encerramento sob trafego (detector de
  deadlock). Versao DUnitX; espelha a versao FPCUnit em tests/Integration/fpc. }

interface

uses
  DUnitX.TestFramework,
  SysUtils,
  Classes,
  SyncObjs,
  Pipes.Types,
  Pipes.Threading,
  Pipes.Framing,
  Pipes.Server,
  Pipes.Client;

type
  [TestFixture]
  TPipeEndToEndTests = class
  private
    FServer: TNamedPipeServer;
    FClient: TNamedPipeClient;
    FLock: TCriticalSection;    // protege FServerTexts/FClientTexts/FLastConnId
    FServerTexts: TStringList;
    FClientTexts: TStringList;
    FLastConnId: TPipeConnectionId;
    FSrvMsgCount: Integer;      // atomicos
    FCliMsgCount: Integer;
    FConnectedCount: Integer;
    FSrvDiscCount: Integer;
    FCliDiscCount: Integer;
    FCliConnCount: Integer;
    // Handlers ('of object'):
    procedure OnSrvMessage(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure OnCliMessage(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure OnSrvClientConnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnSrvClientDisconnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnCliDisconnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnCliConnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnSrvRequestEco(Sender: TObject; AConnId: TPipeConnectionId;
      const ARequest: TBytes; out AReply: TBytes);
    procedure OnSrvRequestLento(Sender: TObject; AConnId: TPipeConnectionId;
      const ARequest: TBytes; out AReply: TBytes);
    procedure DoSendToInvalid;
    procedure DoRequestNoHandler;
    procedure DoRequestShortTimeout;
    // Sobe servidor+cliente conectados com os handlers acima.
    procedure OpenPair(ADispatchMode: TPipeDispatchMode = pdmPool);
    function WaitCount(var ACounter: Integer; AExpected: Integer;
      ATimeoutMs: Cardinal): Boolean;
  public
    [Setup] procedure SetUp;
    [TearDown] procedure TearDown;
  published
    [Test] procedure MensagemDoClienteChegaAoServidor;
    [Test] procedure ServidorRespondeAoCliente;
    [Test] procedure OrdemPreservadaComSerialized;
    [Test] procedure TresClientesSimultaneos;
    [Test] procedure DisconnectDoClienteDisparaEventoNoServidor;
    [Test] procedure DisconnectClientDoServidorDerrubaCliente;
    [Test] procedure StopComTrafego_TerminaRapido;
    [Test] procedure SendParaConexaoInexistente_Levanta;
    [Test] procedure Broadcast_AtingeTodosOsClientes;
    [Test] procedure RequestReply_EcoaComCorrelacao;
    [Test] procedure Request_SemHandler_LevantaEPipeError;
    [Test] procedure Request_Timeout_LevantaEPipeTimeout;
    [Test] procedure AutoReconnect_ReconectaAposRestartDoServidor;
    [Test] procedure MainThread_EventosViaCheckSynchronize;
  end;

implementation

// Comparacao nao-generica (evita E2532 com NativeInt no Win64).
procedure EqualInt(AExpected, AActual: Integer);
begin
  Assert.AreEqual(AExpected, AActual);
end;

var
  GNameSeq: Integer;

function UniquePipeName: string;
begin
  Result := 'pipes_faa_e2e_' + IntToStr(Int64(PipeTickMs)) + '_' +
    IntToStr(PipeAtomicInc(GNameSeq));
end;

{ TPipeEndToEndTests }

procedure TPipeEndToEndTests.SetUp;
begin
  FLock := TCriticalSection.Create;
  FServerTexts := TStringList.Create;
  FClientTexts := TStringList.Create;
  FLastConnId := 0;
  FSrvMsgCount := 0;
  FCliMsgCount := 0;
  FConnectedCount := 0;
  FSrvDiscCount := 0;
  FCliDiscCount := 0;
end;

procedure TPipeEndToEndTests.TearDown;
begin
  FreeAndNil(FClient);  // Disconnect no destructor
  FreeAndNil(FServer);  // Stop no destructor
  FreeAndNil(FServerTexts);
  FreeAndNil(FClientTexts);
  FreeAndNil(FLock);
end;

function TPipeEndToEndTests.WaitCount(var ACounter: Integer;
  AExpected: Integer; ATimeoutMs: Cardinal): Boolean;
var
  LDeadline: UInt64;
begin
  LDeadline := PipeTickMs + ATimeoutMs;
  while (PipeAtomicGet(ACounter) < AExpected) and (PipeTickMs < LDeadline) do
    Sleep(5);
  Result := PipeAtomicGet(ACounter) >= AExpected;
end;

procedure TPipeEndToEndTests.OnSrvMessage(Sender: TObject;
  AConnId: TPipeConnectionId; const AData: TBytes);
begin
  FLock.Enter;
  try
    FServerTexts.Add(PipeUtf8Decode(AData));
  finally
    FLock.Leave;
  end;
  PipeAtomicInc(FSrvMsgCount);
end;

procedure TPipeEndToEndTests.OnCliMessage(Sender: TObject;
  AConnId: TPipeConnectionId; const AData: TBytes);
begin
  FLock.Enter;
  try
    FClientTexts.Add(PipeUtf8Decode(AData));
  finally
    FLock.Leave;
  end;
  PipeAtomicInc(FCliMsgCount);
end;

procedure TPipeEndToEndTests.OnSrvClientConnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  FLock.Enter;
  try
    FLastConnId := AConnId;
  finally
    FLock.Leave;
  end;
  PipeAtomicInc(FConnectedCount);
end;

procedure TPipeEndToEndTests.OnSrvClientDisconnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  PipeAtomicInc(FSrvDiscCount);
end;

procedure TPipeEndToEndTests.OnCliDisconnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  PipeAtomicInc(FCliDiscCount);
end;

procedure TPipeEndToEndTests.OnCliConnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  PipeAtomicInc(FCliConnCount);
end;

procedure TPipeEndToEndTests.OnSrvRequestEco(Sender: TObject;
  AConnId: TPipeConnectionId; const ARequest: TBytes; out AReply: TBytes);
begin
  AReply := PipeUtf8Encode('eco:' + PipeUtf8Decode(ARequest));
end;

procedure TPipeEndToEndTests.OnSrvRequestLento(Sender: TObject;
  AConnId: TPipeConnectionId; const ARequest: TBytes; out AReply: TBytes);
begin
  Sleep(800); // maior que o timeout do teste (200 ms)
  AReply := PipeUtf8Encode('tarde demais');
end;

procedure TPipeEndToEndTests.DoSendToInvalid;
begin
  FServer.SendBytes(999999, PipeUtf8Encode('x'));
end;

procedure TPipeEndToEndTests.DoRequestNoHandler;
begin
  FClient.Request(PipeUtf8Encode('x'), 3000);
end;

procedure TPipeEndToEndTests.DoRequestShortTimeout;
begin
  FClient.Request(PipeUtf8Encode('x'), 200);
end;

procedure TPipeEndToEndTests.OpenPair(ADispatchMode: TPipeDispatchMode);
var
  LName: string;
begin
  LName := UniquePipeName;
  FServer := TNamedPipeServer.Create(LName);
  FServer.DispatchMode := ADispatchMode;
  FServer.OnMessage := OnSrvMessage;
  FServer.OnClientConnected := OnSrvClientConnected;
  FServer.OnClientDisconnected := OnSrvClientDisconnected;
  FServer.Listen;

  FClient := TNamedPipeClient.Create(LName);
  FClient.OnMessage := OnCliMessage;
  FClient.OnDisconnected := OnCliDisconnected;
  FClient.OnConnected := OnCliConnected;
  FClient.Connect(3000);
  Assert.IsTrue(WaitCount(FConnectedCount, 1, 3000), 'OnClientConnected nao disparou');
end;

procedure TPipeEndToEndTests.MensagemDoClienteChegaAoServidor;
begin
  OpenPair;
  FClient.SendText('ola servidor');
  Assert.IsTrue(WaitCount(FSrvMsgCount, 1, 3000), 'mensagem nao chegou ao servidor');
  FLock.Enter;
  try
    Assert.AreEqual('ola servidor', FServerTexts[0]);
    Assert.IsTrue(FLastConnId > 0, 'connId devia ser > 0');
  finally
    FLock.Leave;
  end;
end;

procedure TPipeEndToEndTests.ServidorRespondeAoCliente;
var
  LConnId: TPipeConnectionId;
begin
  OpenPair;
  FLock.Enter;
  try
    LConnId := FLastConnId;
  finally
    FLock.Leave;
  end;
  FServer.SendText(LConnId, 'bem-vindo');
  Assert.IsTrue(WaitCount(FCliMsgCount, 1, 3000), 'resposta nao chegou ao cliente');
  FLock.Enter;
  try
    Assert.AreEqual('bem-vindo', FClientTexts[0]);
  finally
    FLock.Leave;
  end;
end;

procedure TPipeEndToEndTests.OrdemPreservadaComSerialized;
var
  I: Integer;
begin
  OpenPair(pdmSerialized);
  for I := 1 to 30 do
    FClient.SendText('m' + IntToStr(I));
  Assert.IsTrue(WaitCount(FSrvMsgCount, 30, 5000), 'nem todas as mensagens chegaram');
  FLock.Enter;
  try
    EqualInt(30, FServerTexts.Count);
    for I := 1 to 30 do
      Assert.AreEqual('m' + IntToStr(I), FServerTexts[I - 1]);
  finally
    FLock.Leave;
  end;
end;

procedure TPipeEndToEndTests.TresClientesSimultaneos;
var
  LClients: array[0..2] of TNamedPipeClient;
  I: Integer;
  LAll: string;
begin
  OpenPair;
  LClients[0] := nil; LClients[1] := nil; LClients[2] := nil;
  try
    for I := 0 to 2 do
    begin
      LClients[I] := TNamedPipeClient.Create(FServer.PipeName);
      LClients[I].Connect(3000);
      LClients[I].SendText('extra' + IntToStr(I + 1));
    end;
    Assert.IsTrue(WaitCount(FSrvMsgCount, 3, 5000), 'mensagens dos 3 clientes nao chegaram');
    Assert.IsTrue(WaitCount(FConnectedCount, 4, 3000), '4 conexoes esperadas');
    EqualInt(4, FServer.ClientCount);
    FLock.Enter;
    try
      FServerTexts.Sort;
      LAll := FServerTexts.CommaText;
    finally
      FLock.Leave;
    end;
    Assert.AreEqual('extra1,extra2,extra3', LAll);
  finally
    for I := 0 to 2 do
      LClients[I].Free;
  end;
end;

procedure TPipeEndToEndTests.DisconnectDoClienteDisparaEventoNoServidor;
begin
  OpenPair;
  FClient.Disconnect;
  Assert.IsTrue(WaitCount(FSrvDiscCount, 1, 3000),
    'OnClientDisconnected nao disparou no servidor');
  Assert.IsTrue(WaitCount(FCliDiscCount, 1, 3000),
    'OnDisconnected nao disparou no cliente');
  EqualInt(0, FServer.ClientCount);
end;

procedure TPipeEndToEndTests.DisconnectClientDoServidorDerrubaCliente;
var
  LConnId: TPipeConnectionId;
begin
  OpenPair;
  FLock.Enter;
  try
    LConnId := FLastConnId;
  finally
    FLock.Leave;
  end;
  FServer.DisconnectClient(LConnId);
  Assert.IsTrue(WaitCount(FSrvDiscCount, 1, 3000),
    'OnClientDisconnected nao disparou no servidor');
  Assert.IsTrue(WaitCount(FCliDiscCount, 1, 3000),
    'cliente nao percebeu a desconexao');
  Assert.IsFalse(FClient.Connected, 'cliente devia constar como desconectado');
end;

procedure TPipeEndToEndTests.StopComTrafego_TerminaRapido;
var
  I: Integer;
  T0: UInt64;
begin
  OpenPair;
  for I := 1 to 20 do
    FClient.SendText('trafego' + IntToStr(I));
  T0 := PipeTickMs;
  FServer.Stop;
  Assert.IsTrue(PipeTickMs - T0 < 2000, 'Stop sob trafego demorou demais (deadlock?)');
  Assert.IsFalse(FServer.Active, 'servidor devia estar inativo');
  Assert.IsTrue(WaitCount(FCliDiscCount, 1, 3000),
    'cliente nao percebeu o Stop do servidor');
end;

procedure TPipeEndToEndTests.SendParaConexaoInexistente_Levanta;
begin
  OpenPair;
  Assert.WillRaise(DoSendToInvalid, EPipeError);
end;

procedure TPipeEndToEndTests.Broadcast_AtingeTodosOsClientes;
var
  LC2, LC3: TNamedPipeClient;
  I: Integer;
begin
  OpenPair;
  LC2 := TNamedPipeClient.Create(FServer.PipeName);
  LC3 := TNamedPipeClient.Create(FServer.PipeName);
  try
    LC2.OnMessage := OnCliMessage;
    LC3.OnMessage := OnCliMessage;
    LC2.Connect(3000);
    LC3.Connect(3000);
    Assert.IsTrue(WaitCount(FConnectedCount, 3, 3000), '3 conexoes esperadas');
    FServer.BroadcastText('aviso geral');
    Assert.IsTrue(WaitCount(FCliMsgCount, 3, 5000), 'broadcast nao atingiu os 3 clientes');
    FLock.Enter;
    try
      EqualInt(3, FClientTexts.Count);
      for I := 0 to 2 do
        Assert.AreEqual('aviso geral', FClientTexts[I]);
    finally
      FLock.Leave;
    end;
  finally
    LC2.Free;
    LC3.Free;
  end;
end;

procedure TPipeEndToEndTests.RequestReply_EcoaComCorrelacao;
begin
  OpenPair;
  FServer.OnRequest := OnSrvRequestEco;
  Assert.AreEqual('eco:abc', FClient.RequestText('abc', 3000));
  Assert.AreEqual('eco:xyz', FClient.RequestText('xyz', 3000));
end;

procedure TPipeEndToEndTests.Request_SemHandler_LevantaEPipeError;
var
  T0: UInt64;
begin
  OpenPair; // sem OnRequest atribuido
  T0 := PipeTickMs;
  Assert.WillRaise(DoRequestNoHandler, EPipeError);
  // Voltou pelo reply de erro do servidor, nao pelo timeout de 3000 ms.
  Assert.IsTrue(PipeTickMs - T0 < 2000,
    'devia falhar rapido (reply de erro), nao por timeout');
end;

procedure TPipeEndToEndTests.Request_Timeout_LevantaEPipeTimeout;
var
  T0: UInt64;
begin
  OpenPair;
  FServer.OnRequest := OnSrvRequestLento; // dorme 800 ms; timeout = 200 ms
  T0 := PipeTickMs;
  Assert.WillRaise(DoRequestShortTimeout, EPipeTimeout);
  Assert.IsTrue(PipeTickMs - T0 >= 180, 'timeout retornou cedo demais');
  Assert.IsTrue(PipeTickMs - T0 < 3000, 'timeout demorou demais');
end;

procedure TPipeEndToEndTests.AutoReconnect_ReconectaAposRestartDoServidor;
var
  LName: string;
begin
  LName := UniquePipeName;
  FServer := TNamedPipeServer.Create(LName);
  FServer.OnMessage := OnSrvMessage;
  FServer.Listen;

  FClient := TNamedPipeClient.Create(LName);
  FClient.OnConnected := OnCliConnected;
  FClient.OnDisconnected := OnCliDisconnected;
  FClient.AutoReconnect := True;
  FClient.ReconnectDelayMs := 300;
  FClient.Connect(3000);
  Assert.IsTrue(WaitCount(FCliConnCount, 1, 3000), 'primeira conexao nao confirmou');

  FServer.Stop; // derruba o cliente
  Assert.IsTrue(WaitCount(FCliDiscCount, 1, 5000), 'queda nao notificada');

  FServer.Listen; // "restart" do servidor no mesmo nome
  Assert.IsTrue(WaitCount(FCliConnCount, 2, 10000), 'cliente nao reconectou');

  FClient.SendText('depois da reconexao');
  Assert.IsTrue(WaitCount(FSrvMsgCount, 1, 5000), 'mensagem pos-reconexao nao chegou');
  FLock.Enter;
  try
    Assert.AreEqual('depois da reconexao', FServerTexts[0]);
  finally
    FLock.Leave;
  end;
end;

procedure TPipeEndToEndTests.MainThread_EventosViaCheckSynchronize;
var
  LName: string;
  LDeadline: UInt64;
  I: Integer;
begin
  LName := UniquePipeName;
  FServer := TNamedPipeServer.Create(LName);
  FServer.DispatchMode := pdmMainThread;
  FServer.OnMessage := OnSrvMessage;
  FServer.Listen;

  FClient := TNamedPipeClient.Create(LName);
  FClient.Connect(3000);
  FClient.SendText('via main thread');

  // Console: quem drena a fila da main thread e' o CheckSynchronize (num app
  // LCL/VCL o proprio loop de mensagens faz isso).
  LDeadline := PipeTickMs + 5000;
  while (PipeAtomicGet(FSrvMsgCount) < 1) and (PipeTickMs < LDeadline) do
    CheckSynchronize(10);
  EqualInt(1, PipeAtomicGet(FSrvMsgCount));
  FLock.Enter;
  try
    Assert.AreEqual('via main thread', FServerTexts[0]);
  finally
    FLock.Leave;
  end;

  // Libera dentro do teste e drena stragglers da fila da main thread (um
  // evento pos-destroy vira no-op pela guarda; drenar evita falso leak).
  FreeAndNil(FClient);
  FreeAndNil(FServer);
  for I := 1 to 5 do
    CheckSynchronize(10);
end;

initialization
  TDUnitX.RegisterTestFixture(TPipeEndToEndTests);

end.
