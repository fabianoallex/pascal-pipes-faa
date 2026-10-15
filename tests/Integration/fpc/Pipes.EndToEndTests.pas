unit Pipes.EndToEndTests;

{$mode delphi}{$H+}

{ Testes fim-a-fim da camada de alto nivel (TNamedPipeServer/TNamedPipeClient):
  mensagens nos dois sentidos, eventos de conexao/desconexao, ordem com
  pdmSerialized, multiplos clientes e encerramento sob trafego (detector de
  deadlock). Versao FPCUnit; espelha a versao DUnitX em tests/Integration. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  Classes,
  SyncObjs,
  Pipes.Types,
  PascalCommon.Threading,
  Pipes.Framing,
  Pipes.Server,
  Pipes.Client;

type
  TPipeEndToEndTests = class(TTestCase)
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
    // Quantos OnClientConnected ja haviam disparado quando a PRIMEIRA
    // mensagem chegou; -1 = nenhuma mensagem chegou ainda.
    FConnCountAtFirstMsg: Integer;
    // Usados so' pelos testes de AGroupKey (SendBytes): CAS num flag
    // compartilhado detecta duas mensagens da MESMA chave rodando ao mesmo
    // tempo mesmo em pdmPool.
    FGroupBusy: Integer;
    FGroupViolation: Integer;
    // Excecao em handler -> OnError (0.2.0). FErrText/FErrConnId sob FLock.
    FSrvErrCount: Integer;      // atomicos
    FCliErrCount: Integer;
    FErrText: string;
    FErrConnId: TPipeConnectionId;
    // True: WaitCount drena a fila da main thread (pdmMainThread no console).
    FPumpMain: Boolean;
    // Handlers ('of object'):
    procedure OnSrvMessage(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure OnSrvMessageGrouped(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure OnSrvMessageSlow(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure OnCliMessage(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure OnSrvClientConnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnSrvClientDisconnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnCliDisconnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnCliConnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnSrvMessageBoom(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure OnCliMessageBoom(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure OnSrvClientConnectedBoom(Sender: TObject;
      AConnId: TPipeConnectionId);
    procedure OnSrvError(Sender: TObject; AConnId: TPipeConnectionId;
      const AMsg: string);
    procedure OnSrvErrorRaising(Sender: TObject; AConnId: TPipeConnectionId;
      const AMsg: string);
    procedure OnCliError(Sender: TObject; AConnId: TPipeConnectionId;
      const AMsg: string);
    // Excecao no OnMessage do servidor com o DispatchMode/chave dados.
    procedure CheckOnMessageExceptionReachesOnError(AMode: TPipeDispatchMode;
      const AGroupKey: string);
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
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure MensagemDoClienteChegaAoServidor;
    procedure ServidorRespondeAoCliente;
    procedure OrdemPreservadaComSerialized;
    procedure ConectadoAntesDaPrimeiraMensagem;
    procedure TresClientesSimultaneos;
    procedure DisconnectDoClienteDisparaEventoNoServidor;
    procedure DisconnectClientDoServidorDerrubaCliente;
    procedure StopComTrafego_TerminaRapido;
    procedure SendParaConexaoInexistente_Levanta;
    procedure Broadcast_AtingeTodosOsClientes;
    procedure RequestReply_EcoaComCorrelacao;
    procedure Request_SemHandler_LevantaEPipeError;
    procedure Request_Timeout_LevantaEPipeTimeout;
    procedure AutoReconnect_ReconectaAposRestartDoServidor;
    procedure MainThread_EventosViaCheckSynchronize;
    procedure SendBytesBatch_ClienteParaServidor_ChegamNaOrdem;
    procedure SendBytesBatch_ServidorParaCliente_ChegamNaOrdem;
    procedure SendBytesBatch_Vazio_NaoEnviaNada;
    procedure SendBytesComGrupo_MesmaChave_PreservaOrdemSobPdmPool;
    procedure SendBytesComGrupo_ChavesDiferentes_NaoBloqueiamEntreSi;
    procedure Compressao_ClienteParaServidor_ChegaIntegroEStatsLogicos;
    procedure Compressao_ServidorParaCliente_ChegaIntegro;
    procedure ExcecaoNoOnMessage_Pool_ViraOnErrorEConexaoSegue;
    procedure ExcecaoNoOnMessage_Serialized_ViraOnError;
    procedure ExcecaoNoOnMessage_ComGrupo_ViraOnError;
    procedure ExcecaoNoOnMessage_MainThread_ViraOnError;
    procedure ExcecaoNoOnMessageDoCliente_ViraOnErrorDoCliente;
    procedure ExcecaoNoOnClientConnected_ViraOnErrorComNomeDoEvento;
    procedure ExcecaoNoProprioOnError_EngolidaSemRecursao;
  end;

implementation

var
  GNameSeq: Integer;

function UniquePipeName: string;
begin
  Result := 'pipes_faa_e2e_' + IntToStr(Int64(PcTickMs)) + '_' +
    IntToStr(PcAtomicInc(GNameSeq));
end;

{ TPipeEndToEndTests }

procedure TPipeEndToEndTests.SetUp;
begin
  inherited;
  FLock := TCriticalSection.Create;
  FConnCountAtFirstMsg := -1;
  FServerTexts := TStringList.Create;
  FClientTexts := TStringList.Create;
  FLastConnId := 0;
  FSrvMsgCount := 0;
  FCliMsgCount := 0;
  FConnectedCount := 0;
  FSrvDiscCount := 0;
  FCliDiscCount := 0;
  FGroupBusy := 0;
  FGroupViolation := 0;
  FSrvErrCount := 0;
  FCliErrCount := 0;
  FErrText := '';
  FErrConnId := 0;
  FPumpMain := False;
end;

procedure TPipeEndToEndTests.TearDown;
begin
  FreeAndNil(FClient);  // Disconnect no destructor
  FreeAndNil(FServer);  // Stop no destructor
  FreeAndNil(FServerTexts);
  FreeAndNil(FClientTexts);
  FreeAndNil(FLock);
  inherited;
end;

function TPipeEndToEndTests.WaitCount(var ACounter: Integer;
  AExpected: Integer; ATimeoutMs: Cardinal): Boolean;
var
  LDeadline: UInt64;
begin
  LDeadline := PcTickMs + ATimeoutMs;
  while (PcAtomicGet(ACounter) < AExpected) and (PcTickMs < LDeadline) do
    if FPumpMain then
      CheckSynchronize(5)
    else
      Sleep(5);
  Result := PcAtomicGet(ACounter) >= AExpected;
end;

procedure TPipeEndToEndTests.OnSrvMessage(Sender: TObject;
  AConnId: TPipeConnectionId; const AData: TBytes);
begin
  FLock.Enter;
  try
    if FServerTexts.Count = 0 then
      FConnCountAtFirstMsg := PcAtomicGet(FConnectedCount);
    FServerTexts.Add(PipeUtf8Decode(AData));
  finally
    FLock.Leave;
  end;
  PcAtomicInc(FSrvMsgCount);
end;

procedure TPipeEndToEndTests.OnSrvMessageGrouped(Sender: TObject;
  AConnId: TPipeConnectionId; const AData: TBytes);
begin
  if PcAtomicCompareExchange(FGroupBusy, 1, 0) <> 0 then
    PcAtomicSet(FGroupViolation, 1); // outra msg da MESMA chave ja rodando
  try
    Sleep(3); // alarga a janela: dispatch quebrado sobreporia aqui
    FLock.Enter;
    try
      FServerTexts.Add(PipeUtf8Decode(AData));
    finally
      FLock.Leave;
    end;
  finally
    PcAtomicSet(FGroupBusy, 0);
  end;
  PcAtomicInc(FSrvMsgCount);
end;

procedure TPipeEndToEndTests.OnSrvMessageSlow(Sender: TObject;
  AConnId: TPipeConnectionId; const AData: TBytes);
begin
  Sleep(200); // fixo: mede se duas chaves diferentes correm em paralelo
  FLock.Enter;
  try
    FServerTexts.Add(PipeUtf8Decode(AData));
  finally
    FLock.Leave;
  end;
  PcAtomicInc(FSrvMsgCount);
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
  PcAtomicInc(FCliMsgCount);
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
  PcAtomicInc(FConnectedCount);
end;

procedure TPipeEndToEndTests.OnSrvClientDisconnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  PcAtomicInc(FSrvDiscCount);
end;

procedure TPipeEndToEndTests.OnCliDisconnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  PcAtomicInc(FCliDiscCount);
end;

procedure TPipeEndToEndTests.OnCliConnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  PcAtomicInc(FCliConnCount);
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
  AssertTrue('OnClientConnected nao disparou', WaitCount(FConnectedCount, 1, 3000));
end;

procedure TPipeEndToEndTests.MensagemDoClienteChegaAoServidor;
begin
  OpenPair;
  FClient.SendText('ola servidor');
  AssertTrue('mensagem nao chegou ao servidor', WaitCount(FSrvMsgCount, 1, 3000));
  FLock.Enter;
  try
    AssertEquals('ola servidor', FServerTexts[0]);
    AssertTrue('connId devia ser > 0', FLastConnId > 0);
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
  AssertTrue('resposta nao chegou ao cliente', WaitCount(FCliMsgCount, 1, 3000));
  FLock.Enter;
  try
    AssertEquals('bem-vindo', FClientTexts[0]);
  finally
    FLock.Leave;
  end;
end;

procedure TPipeEndToEndTests.ConectadoAntesDaPrimeiraMensagem;
begin
  // Guarda a ordem documentada: no pdmSerialized, OnClientConnected vem ANTES
  // do primeiro OnMessage da conexao. Quem enfileira os dois e a mesma reader
  // thread, nesta ordem — o teste existe porque o despacho do connected ja
  // morou na thread de accept, e mover isso poderia inverter a ordem sem que
  // nenhum outro teste percebesse.
  OpenPair(pdmSerialized);
  FClient.SendText('primeira');
  AssertTrue('mensagem nao chegou', WaitCount(FSrvMsgCount, 1, 3000));
  AssertEquals('OnClientConnected devia ter disparado antes do primeiro OnMessage',
    1, FConnCountAtFirstMsg);
end;

procedure TPipeEndToEndTests.OrdemPreservadaComSerialized;
var
  I: Integer;
begin
  OpenPair(pdmSerialized);
  for I := 1 to 30 do
    FClient.SendText('m' + IntToStr(I));
  AssertTrue('nem todas as mensagens chegaram', WaitCount(FSrvMsgCount, 30, 5000));
  FLock.Enter;
  try
    AssertEquals(30, FServerTexts.Count);
    for I := 1 to 30 do
      AssertEquals('m' + IntToStr(I), FServerTexts[I - 1]);
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
    AssertTrue('mensagens dos 3 clientes nao chegaram', WaitCount(FSrvMsgCount, 3, 5000));
    AssertTrue('4 conexoes esperadas', WaitCount(FConnectedCount, 4, 3000));
    AssertEquals(4, FServer.ClientCount);
    FLock.Enter;
    try
      FServerTexts.Sort;
      LAll := FServerTexts.CommaText;
    finally
      FLock.Leave;
    end;
    AssertEquals('extra1,extra2,extra3', LAll);
  finally
    for I := 0 to 2 do
      LClients[I].Free;
  end;
end;

procedure TPipeEndToEndTests.DisconnectDoClienteDisparaEventoNoServidor;
begin
  OpenPair;
  FClient.Disconnect;
  AssertTrue('OnClientDisconnected nao disparou no servidor',
    WaitCount(FSrvDiscCount, 1, 3000));
  AssertTrue('OnDisconnected nao disparou no cliente',
    WaitCount(FCliDiscCount, 1, 3000));
  AssertEquals(0, FServer.ClientCount);
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
  AssertTrue('OnClientDisconnected nao disparou no servidor',
    WaitCount(FSrvDiscCount, 1, 3000));
  AssertTrue('cliente nao percebeu a desconexao',
    WaitCount(FCliDiscCount, 1, 3000));
  AssertTrue('cliente devia constar como desconectado', not FClient.Connected);
end;

procedure TPipeEndToEndTests.StopComTrafego_TerminaRapido;
var
  I: Integer;
  T0: UInt64;
begin
  OpenPair;
  for I := 1 to 20 do
    FClient.SendText('trafego' + IntToStr(I));
  T0 := PcTickMs;
  FServer.Stop;
  AssertTrue('Stop sob trafego demorou demais (deadlock?)',
    PcTickMs - T0 < 2000);
  AssertTrue('servidor devia estar inativo', not FServer.Active);
  AssertTrue('cliente nao percebeu o Stop do servidor',
    WaitCount(FCliDiscCount, 1, 3000));
end;

procedure TPipeEndToEndTests.SendParaConexaoInexistente_Levanta;
begin
  OpenPair;
  AssertException(EPipeError, DoSendToInvalid);
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
    AssertTrue('3 conexoes esperadas', WaitCount(FConnectedCount, 3, 3000));
    FServer.BroadcastText('aviso geral');
    AssertTrue('broadcast nao atingiu os 3 clientes', WaitCount(FCliMsgCount, 3, 5000));
    FLock.Enter;
    try
      AssertEquals(3, FClientTexts.Count);
      for I := 0 to 2 do
        AssertEquals('aviso geral', FClientTexts[I]);
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
  AssertEquals('eco:abc', FClient.RequestText('abc', 3000));
  AssertEquals('eco:xyz', FClient.RequestText('xyz', 3000));
end;

procedure TPipeEndToEndTests.Request_SemHandler_LevantaEPipeError;
var
  T0: UInt64;
begin
  OpenPair; // sem OnRequest atribuido
  T0 := PcTickMs;
  AssertException(EPipeError, DoRequestNoHandler);
  // Voltou pelo reply de erro do servidor, nao pelo timeout de 3000 ms.
  AssertTrue('devia falhar rapido (reply de erro), nao por timeout',
    PcTickMs - T0 < 2000);
end;

procedure TPipeEndToEndTests.Request_Timeout_LevantaEPipeTimeout;
var
  T0: UInt64;
begin
  OpenPair;
  FServer.OnRequest := OnSrvRequestLento; // dorme 800 ms; timeout = 200 ms
  T0 := PcTickMs;
  AssertException(EPipeTimeout, DoRequestShortTimeout);
  AssertTrue('timeout retornou cedo demais', PcTickMs - T0 >= 180);
  AssertTrue('timeout demorou demais', PcTickMs - T0 < 3000);
end;

procedure TPipeEndToEndTests.AutoReconnect_ReconectaAposRestartDoServidor;
var
  LName: string;
  LDeadline: UInt64;
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
  AssertTrue('primeira conexao nao confirmou', WaitCount(FCliConnCount, 1, 3000));

  FServer.Stop; // derruba o cliente
  AssertTrue('queda nao notificada', WaitCount(FCliDiscCount, 1, 5000));

  FServer.Listen; // "restart" do servidor no mesmo nome
  AssertTrue('cliente nao reconectou', WaitCount(FCliConnCount, 2, 10000));

  // Contrato do AutoReconnect: um send pode pegar uma janela de churn
  // (EPipeClosed transitorio entre queda e re-reconexao) — o chamador
  // re-tenta, como um app real faria.
  LDeadline := PcTickMs + 5000;
  while True do
  begin
    try
      FClient.SendText('depois da reconexao');
      Break;
    except
      on EPipeClosed do
        if PcTickMs >= LDeadline then
          raise;
    end;
    Sleep(50);
  end;
  AssertTrue('mensagem pos-reconexao nao chegou', WaitCount(FSrvMsgCount, 1, 5000));
  FLock.Enter;
  try
    AssertEquals('depois da reconexao', FServerTexts[0]);
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
  LDeadline := PcTickMs + 5000;
  while (PcAtomicGet(FSrvMsgCount) < 1) and (PcTickMs < LDeadline) do
    CheckSynchronize(10);
  AssertEquals(1, PcAtomicGet(FSrvMsgCount));
  FLock.Enter;
  try
    AssertEquals('via main thread', FServerTexts[0]);
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

procedure TPipeEndToEndTests.SendBytesBatch_ClienteParaServidor_ChegamNaOrdem;
var
  LItems: TArray<TBytes>;
begin
  // A garantia do lote e' de ORDEM NO FIO (mesma sequencia do array, um Write
  // so'); a ordem de ENTREGA ao callback depende do DispatchMode, exatamente
  // como para qualquer sequencia de SendBytes avulsos — dai pdmSerialized
  // aqui, mesmo motivo de OrdemPreservadaComSerialized.
  OpenPair(pdmSerialized);
  SetLength(LItems, 3);
  LItems[0] := PipeUtf8Encode('um');
  LItems[1] := PipeUtf8Encode('dois');
  LItems[2] := PipeUtf8Encode('tres');
  FClient.SendBytesBatch(LItems);
  AssertTrue('lote nao chegou completo ao servidor', WaitCount(FSrvMsgCount, 3, 3000));
  FLock.Enter;
  try
    AssertEquals(3, FServerTexts.Count);
    AssertEquals('um', FServerTexts[0]);
    AssertEquals('dois', FServerTexts[1]);
    AssertEquals('tres', FServerTexts[2]);
  finally
    FLock.Leave;
  end;
end;

procedure TPipeEndToEndTests.SendBytesBatch_ServidorParaCliente_ChegamNaOrdem;
var
  LName: string;
  LItems: TArray<TBytes>;
  LConnId: TPipeConnectionId;
begin
  // Nao usa OpenPair: DispatchMode nao pode mudar com o componente ativo (ver
  // EnsureInactive), entao precisa ser ajustado ANTES do Connect. Ordem de
  // ENTREGA ao OnMessage do cliente passa pelo pool por padrao (mesmo
  // mecanismo de DispatchMessage do lado servidor) — dai pdmSerialized aqui,
  // senao a asserção de ordem valeria so' para o fio, nao para o callback.
  LName := UniquePipeName;
  FServer := TNamedPipeServer.Create(LName);
  FServer.OnMessage := OnSrvMessage;
  FServer.OnClientConnected := OnSrvClientConnected;
  FServer.Listen;

  FClient := TNamedPipeClient.Create(LName);
  FClient.DispatchMode := pdmSerialized;
  FClient.OnMessage := OnCliMessage;
  FClient.Connect(3000);
  AssertTrue('OnClientConnected nao disparou', WaitCount(FConnectedCount, 1, 3000));

  FLock.Enter;
  try
    LConnId := FLastConnId;
  finally
    FLock.Leave;
  end;
  SetLength(LItems, 3);
  LItems[0] := PipeUtf8Encode('a');
  LItems[1] := PipeUtf8Encode('b');
  LItems[2] := PipeUtf8Encode('c');
  FServer.SendBytesBatch(LConnId, LItems);
  AssertTrue('lote nao chegou completo ao cliente', WaitCount(FCliMsgCount, 3, 3000));
  FLock.Enter;
  try
    AssertEquals(3, FClientTexts.Count);
    AssertEquals('a', FClientTexts[0]);
    AssertEquals('b', FClientTexts[1]);
    AssertEquals('c', FClientTexts[2]);
  finally
    FLock.Leave;
  end;
end;

procedure TPipeEndToEndTests.SendBytesBatch_Vazio_NaoEnviaNada;
var
  LItems: TArray<TBytes>;
begin
  OpenPair;
  LItems := nil;
  FClient.SendBytesBatch(LItems); // no-op
  // Se o no-op tivesse escrito algo, essa sentinela nao seria a mensagem [0].
  FClient.SendText('sentinela');
  AssertTrue(WaitCount(FSrvMsgCount, 1, 3000));
  FLock.Enter;
  try
    AssertEquals(1, FServerTexts.Count);
    AssertEquals('sentinela', FServerTexts[0]);
  finally
    FLock.Leave;
  end;
end;

procedure TPipeEndToEndTests.SendBytesComGrupo_MesmaChave_PreservaOrdemSobPdmPool;
const
  N = 25;
var
  I: Integer;
begin
  // pdmPool e' o padrao (nao serializado) - e' exatamente onde a garantia de
  // AGroupKey precisa aparecer, ja' que sem ela pdmPool nao ordena a entrega.
  OpenPair;
  FServer.OnMessage := OnSrvMessageGrouped;
  for I := 1 to N do
    FClient.SendBytes(PipeUtf8Encode(IntToStr(I)), 'caixa-3');
  AssertTrue('nem todas as mensagens do grupo chegaram',
    WaitCount(FSrvMsgCount, N, 5000));
  AssertEquals('duas mensagens do MESMO grupo rodaram sobrepostas em pdmPool',
    0, PcAtomicGet(FGroupViolation));
  FLock.Enter;
  try
    AssertEquals(N, FServerTexts.Count);
    for I := 1 to N do
      AssertEquals('ordem do grupo nao preservada na entrega (pdmPool)',
        IntToStr(I), FServerTexts[I - 1]);
  finally
    FLock.Leave;
  end;
end;

procedure TPipeEndToEndTests.SendBytesComGrupo_ChavesDiferentes_NaoBloqueiamEntreSi;
var
  T0: UInt64;
begin
  OpenPair;
  FServer.OnMessage := OnSrvMessageSlow;
  T0 := PcTickMs;
  FClient.SendBytes(PipeUtf8Encode('a'), 'grupoA');
  FClient.SendBytes(PipeUtf8Encode('b'), 'grupoB');
  AssertTrue('as duas mensagens nao chegaram', WaitCount(FSrvMsgCount, 2, 3000));
  // Serializado (bug) levaria ~400ms; em paralelo, ~200ms — folga generosa.
  AssertTrue('chaves diferentes nao processaram em paralelo (parece serializado)',
    PcTickMs - T0 < 350);
end;

procedure TPipeEndToEndTests.Compressao_ClienteParaServidor_ChegaIntegroEStatsLogicos;
var
  LName, LTexto: string;
  LStats: TPipeServerStats;
begin
  LName := UniquePipeName;
  FServer := TNamedPipeServer.Create(LName);
  FServer.OnMessage := OnSrvMessage;
  FServer.OnClientConnected := OnSrvClientConnected;
  FServer.Listen;

  FClient := TNamedPipeClient.Create(LName);
  FClient.CompressionMinSize := 256; // liga a PRODUCAO so' deste lado
  FClient.Connect(3000);
  AssertTrue('OnClientConnected nao disparou', WaitCount(FConnectedCount, 1, 3000));

  // Repetitivo e acima do minimo: o cliente vai mandar isto como
  // pfkCompressed de verdade, nao so' exercitar o caminho desligado.
  LTexto := StringOfChar('A', 20000);
  FClient.SendText(LTexto);
  AssertTrue('mensagem nao chegou ao servidor', WaitCount(FSrvMsgCount, 1, 3000));
  FLock.Enter;
  try
    AssertEquals('payload deveria chegar integro depois de descomprimido no servidor',
      LTexto, FServerTexts[0]);
  finally
    FLock.Leave;
  end;

  // Stats contam o payload LOGICO (pre-compressao): tem que bater com o
  // texto original de 20000 bytes, nao com o tamanho reduzido que passou
  // pelo fio.
  LStats := FServer.Stats;
  AssertTrue('Stats deveriam contar o payload logico, nao o comprimido no fio',
    LStats.TotalBytesReceived >= UInt64(Length(PipeUtf8Encode(LTexto))));
end;

procedure TPipeEndToEndTests.Compressao_ServidorParaCliente_ChegaIntegro;
var
  LName, LTexto: string;
  LConnId: TPipeConnectionId;
begin
  LName := UniquePipeName;
  FServer := TNamedPipeServer.Create(LName);
  FServer.CompressionMinSize := 256; // liga a PRODUCAO so' deste lado
  FServer.OnClientConnected := OnSrvClientConnected;
  FServer.Listen;

  FClient := TNamedPipeClient.Create(LName);
  FClient.OnMessage := OnCliMessage;
  FClient.Connect(3000);
  AssertTrue('OnClientConnected nao disparou', WaitCount(FConnectedCount, 1, 3000));

  FLock.Enter;
  try
    LConnId := FLastConnId;
  finally
    FLock.Leave;
  end;

  LTexto := StringOfChar('B', 20000);
  FServer.SendText(LConnId, LTexto);
  AssertTrue('mensagem nao chegou ao cliente', WaitCount(FCliMsgCount, 1, 3000));
  FLock.Enter;
  try
    AssertEquals('payload deveria chegar integro depois de descomprimido no cliente',
      LTexto, FClientTexts[0]);
  finally
    FLock.Leave;
  end;
end;

procedure TPipeEndToEndTests.OnSrvMessageBoom(Sender: TObject;
  AConnId: TPipeConnectionId; const AData: TBytes);
begin
  // Simula o FromJson de um DTO recusando o payload.
  if PipeUtf8Decode(AData) = 'boom' then
    raise EConvertError.Create('$.quantity: nao e numero');
  OnSrvMessage(Sender, AConnId, AData);
end;

procedure TPipeEndToEndTests.OnCliMessageBoom(Sender: TObject;
  AConnId: TPipeConnectionId; const AData: TBytes);
begin
  if PipeUtf8Decode(AData) = 'boom' then
    raise EConvertError.Create('cliente recusou');
  OnCliMessage(Sender, AConnId, AData);
end;

procedure TPipeEndToEndTests.OnSrvClientConnectedBoom(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  OnSrvClientConnected(Sender, AConnId);
  raise EInvalidOperation.Create('falhou no connected');
end;

procedure TPipeEndToEndTests.OnSrvError(Sender: TObject;
  AConnId: TPipeConnectionId; const AMsg: string);
begin
  FLock.Enter;
  try
    FErrText := AMsg;
    FErrConnId := AConnId;
  finally
    FLock.Leave;
  end;
  PcAtomicInc(FSrvErrCount);
end;

procedure TPipeEndToEndTests.OnSrvErrorRaising(Sender: TObject;
  AConnId: TPipeConnectionId; const AMsg: string);
begin
  OnSrvError(Sender, AConnId, AMsg);
  raise Exception.Create('falhou dentro do OnError');
end;

procedure TPipeEndToEndTests.OnCliError(Sender: TObject;
  AConnId: TPipeConnectionId; const AMsg: string);
begin
  FLock.Enter;
  try
    FErrText := AMsg;
    FErrConnId := AConnId;
  finally
    FLock.Leave;
  end;
  PcAtomicInc(FCliErrCount);
end;

procedure TPipeEndToEndTests.CheckOnMessageExceptionReachesOnError(
  AMode: TPipeDispatchMode; const AGroupKey: string);
var
  LName: string;
  I: Integer;
begin
  // Ate a 0.1.1 a excecao era engolida pelo worker do pool (ou pelo
  // TPipeQueuedEvent em pdmMainThread) e o OnError nunca disparava.
  FPumpMain := AMode = pdmMainThread;
  LName := UniquePipeName;
  FServer := TNamedPipeServer.Create(LName);
  FServer.DispatchMode := AMode;
  FServer.OnMessage := OnSrvMessageBoom;
  FServer.OnError := OnSrvError;
  FServer.OnClientConnected := OnSrvClientConnected;
  FServer.Listen;

  FClient := TNamedPipeClient.Create(LName);
  FClient.OnError := OnCliError;
  FClient.Connect(3000);
  AssertTrue('OnClientConnected nao disparou', WaitCount(FConnectedCount, 1, 3000));

  FClient.SendText('boom', AGroupKey);
  FClient.SendText('depois', AGroupKey);
  AssertTrue('excecao do OnMessage nao chegou ao OnError', WaitCount(FSrvErrCount, 1, 3000));
  AssertTrue('mensagem seguinte nao chegou (conexao caiu?)', WaitCount(FSrvMsgCount, 1, 3000));
  FLock.Enter;
  try
    AssertEquals('OnMessage levantou EConvertError: $.quantity: nao e numero', FErrText);
    AssertTrue('OnError devia trazer o ConnId da mensagem', FErrConnId = FLastConnId);
    AssertEquals('depois', FServerTexts[0]);
  finally
    FLock.Leave;
  end;
  AssertTrue('OnError devia disparar uma vez', PcAtomicGet(FSrvErrCount) = 1);
  AssertTrue('o cliente nao devia receber erro', PcAtomicGet(FCliErrCount) = 0);
  AssertTrue('a conexao devia continuar aberta', FServer.ClientCount = 1);
  AssertTrue('o cliente devia continuar conectado', FClient.Connected);

  if FPumpMain then
  begin
    // Mesmo cuidado de MainThread_EventosViaCheckSynchronize.
    FreeAndNil(FClient);
    FreeAndNil(FServer);
    for I := 1 to 5 do
      CheckSynchronize(10);
  end;
end;

procedure TPipeEndToEndTests.ExcecaoNoOnMessage_Pool_ViraOnErrorEConexaoSegue;
begin
  CheckOnMessageExceptionReachesOnError(pdmPool, '');
end;

procedure TPipeEndToEndTests.ExcecaoNoOnMessage_Serialized_ViraOnError;
begin
  CheckOnMessageExceptionReachesOnError(pdmSerialized, '');
end;

procedure TPipeEndToEndTests.ExcecaoNoOnMessage_ComGrupo_ViraOnError;
begin
  // AGroupKey em pdmPool passa pelo TPipeMailboxDrainWork, outro except.
  CheckOnMessageExceptionReachesOnError(pdmPool, 'caixa-1');
end;

procedure TPipeEndToEndTests.ExcecaoNoOnMessage_MainThread_ViraOnError;
begin
  CheckOnMessageExceptionReachesOnError(pdmMainThread, '');
end;

procedure TPipeEndToEndTests.ExcecaoNoOnMessageDoCliente_ViraOnErrorDoCliente;
var
  LConnId: TPipeConnectionId;
begin
  OpenPair;
  FClient.OnMessage := OnCliMessageBoom;
  FClient.OnError := OnCliError;
  FServer.OnError := OnSrvError;
  FLock.Enter;
  try
    LConnId := FLastConnId;
  finally
    FLock.Leave;
  end;
  FServer.SendText(LConnId, 'boom');
  FServer.SendText(LConnId, 'depois');
  AssertTrue('excecao do OnMessage do cliente nao chegou ao OnError', WaitCount(FCliErrCount, 1, 3000));
  AssertTrue('mensagem seguinte nao chegou ao cliente', WaitCount(FCliMsgCount, 1, 3000));
  FLock.Enter;
  try
    AssertEquals('OnMessage levantou EConvertError: cliente recusou', FErrText);
    AssertTrue('no cliente o ConnId e'' sempre 0', FErrConnId = 0);
    AssertEquals('depois', FClientTexts[0]);
  finally
    FLock.Leave;
  end;
  AssertTrue('o servidor nao devia receber erro', PcAtomicGet(FSrvErrCount) = 0);
end;

procedure TPipeEndToEndTests.ExcecaoNoOnClientConnected_ViraOnErrorComNomeDoEvento;
var
  LName: string;
begin
  // Nao so' OnMessage: todo handler do usuario segue a mesma regra.
  LName := UniquePipeName;
  FServer := TNamedPipeServer.Create(LName);
  FServer.OnMessage := OnSrvMessage;
  FServer.OnError := OnSrvError;
  FServer.OnClientConnected := OnSrvClientConnectedBoom;
  FServer.Listen;

  FClient := TNamedPipeClient.Create(LName);
  FClient.Connect(3000);
  AssertTrue('excecao do OnClientConnected nao chegou ao OnError', WaitCount(FSrvErrCount, 1, 3000));
  FLock.Enter;
  try
    AssertEquals('OnClientConnected levantou EInvalidOperation: falhou no connected', FErrText);
    AssertTrue('OnError devia trazer o ConnId da conexao', FErrConnId = FLastConnId);
  finally
    FLock.Leave;
  end;
  FClient.SendText('segue');
  AssertTrue('a conexao devia continuar funcionando', WaitCount(FSrvMsgCount, 1, 3000));
end;

procedure TPipeEndToEndTests.ExcecaoNoProprioOnError_EngolidaSemRecursao;
begin
  OpenPair;
  FServer.OnMessage := OnSrvMessageBoom;
  FServer.OnError := OnSrvErrorRaising;
  FClient.SendText('boom');
  FClient.SendText('depois');
  AssertTrue('OnError nao disparou', WaitCount(FSrvErrCount, 1, 3000));
  AssertTrue('mensagem seguinte nao chegou', WaitCount(FSrvMsgCount, 1, 3000));
  Sleep(200); // uma recursao apareceria como um segundo OnError
  AssertTrue('excecao do OnError nao pode realimentar o OnError', PcAtomicGet(FSrvErrCount) = 1);
  AssertTrue('a conexao devia continuar aberta', FServer.ClientCount = 1);
end;

initialization
  RegisterTest(TPipeEndToEndTests);

end.
