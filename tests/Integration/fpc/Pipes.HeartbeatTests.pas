unit Pipes.HeartbeatTests;

{$mode delphi}{$H+}

{ Testes de integracao do heartbeat de aplicacao
  (Pipes.Base.HeartbeatIntervalMs): deteccao de peer zumbi em ptTcp nos DOIS
  sentidos (servidor detecta cliente silencioso e vice-versa), ptLocal
  ignorando a property (mesma regra de KeepAliveSeconds), e Stop/Disconnect
  terminando rapido com a heartbeat thread nova ativa (sem deadlock na
  StopHeartbeat). "Zumbi" aqui e' literal: um TPipeEndpoint cru que aceita a
  conexao e nunca mais le nem escreve nada — diferente de um FIN limpo, que a
  camada de leitura ja detecta sem heartbeat nenhum.
  Versao FPCUnit; espelha a versao DUnitX em tests/Integration. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  Pipes.Types,
  Pipes.Threading,
  Pipes.Transport,
  Pipes.Server,
  Pipes.Client;

type
  TPipeHeartbeatTests = class(TTestCase)
  private
    FServer: TPipeServer;
    FClient: TPipeClient;
    FSrvDiscCount: Integer; // atomico
    FCliDiscCount: Integer; // atomico
    procedure OnSrvClientDisconnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnCliDisconnected(Sender: TObject; AConnId: TPipeConnectionId);
    function WaitCount(var ACounter: Integer; AExpected: Integer;
      ATimeoutMs: Cardinal): Boolean;
    // Espera o prazo INTEIRO e confirma que o contador NAO alcancou AExpected
    // (prova de ausencia de falso positivo).
    function WaitStill(var ACounter: Integer; AExpected: Integer;
      ATimeoutMs: Cardinal): Boolean;
  protected
    procedure TearDown; override;
  published
    procedure Servidor_DetectaClienteZumbi;
    procedure Cliente_DetectaServidorZumbi;
    procedure PtLocal_IgnoraHeartbeatIntervalMs;
    procedure StopEDisconnect_ComHeartbeatAtivo_TerminamRapido;
  end;

implementation

var
  GNameSeq: Integer;

// Porta nova a cada teste (mesma logica de Pipes.TransportTests: faixa
// abaixo da efemera, para nao esbarrar em reservas dinamicas do Windows).
function UniqueTcpAddress: string;
begin
  Result := '127.0.0.1:' +
    IntToStr(20000 + (Int64(PipeTickMs) mod 18000) + PipeAtomicInc(GNameSeq));
end;

function UniquePipeName: string;
begin
  Result := 'pipes_faa_hb_' + IntToStr(Int64(PipeTickMs)) + '_' +
    IntToStr(PipeAtomicInc(GNameSeq));
end;

{ TPipeHeartbeatTests }

procedure TPipeHeartbeatTests.TearDown;
begin
  FreeAndNil(FClient); // Disconnect no destructor
  FreeAndNil(FServer); // Stop no destructor
  inherited;
end;

function TPipeHeartbeatTests.WaitCount(var ACounter: Integer;
  AExpected: Integer; ATimeoutMs: Cardinal): Boolean;
var
  LDeadline: UInt64;
begin
  LDeadline := PipeTickMs + ATimeoutMs;
  while (PipeAtomicGet(ACounter) < AExpected) and (PipeTickMs < LDeadline) do
    Sleep(5);
  Result := PipeAtomicGet(ACounter) >= AExpected;
end;

function TPipeHeartbeatTests.WaitStill(var ACounter: Integer;
  AExpected: Integer; ATimeoutMs: Cardinal): Boolean;
begin
  Sleep(ATimeoutMs);
  Result := PipeAtomicGet(ACounter) < AExpected;
end;

procedure TPipeHeartbeatTests.OnSrvClientDisconnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  PipeAtomicInc(FSrvDiscCount);
end;

procedure TPipeHeartbeatTests.OnCliDisconnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  PipeAtomicInc(FCliDiscCount);
end;

procedure TPipeHeartbeatTests.Servidor_DetectaClienteZumbi;
var
  LZumbi: TPipeEndpoint;
begin
  FServer := TPipeServer.Create(UniqueTcpAddress, ptTcp);
  FServer.HeartbeatIntervalMs := 150; // morto em ~300ms sem NENHUM frame
  FServer.OnClientDisconnected := OnSrvClientDisconnected;
  FServer.Listen;
  // Cliente "zumbi": abre o socket TCP no nivel de transporte e nunca mais
  // fala nada (nem le os Pings do servidor) — simula um NAT que engoliu o
  // mapeamento mas deixou o socket local vivo do lado do peer.
  LZumbi := PipeConnect(FServer.Address, 3000, ptTcp);
  try
    AssertTrue('servidor nao detectou o cliente zumbi a tempo',
      WaitCount(FSrvDiscCount, 1, 3000));
  finally
    LZumbi.CloseAbort;
    LZumbi.Free;
  end;
end;

procedure TPipeHeartbeatTests.Cliente_DetectaServidorZumbi;
var
  LListener: TPipeListener;
  LServerSide: TPipeEndpoint;
  LAddress: string;
begin
  // Servidor "zumbi": aceita a conexao crua e nunca mais fala nada. Quem tem
  // HeartbeatIntervalMs ligado aqui e' o CLIENTE de alto nivel.
  LAddress := UniqueTcpAddress;
  LListener := PipeCreateListener(LAddress, ptTcp);
  LServerSide := nil;
  try
    FClient := TPipeClient.Create(LAddress, ptTcp);
    FClient.HeartbeatIntervalMs := 150;
    FClient.OnDisconnected := OnCliDisconnected;
    FClient.Connect(3000);
    // Aceita e SEGURA o endpoint cru (nao fecha, nao libera): o socket fica
    // vivo, mas ninguem do lado servidor nunca mais le nem escreve.
    LServerSide := LListener.Accept;
    AssertTrue('cliente nao detectou o servidor zumbi a tempo',
      WaitCount(FCliDiscCount, 1, 3000));
  finally
    LListener.Close;
    LListener.Free;
    LServerSide.Free;
  end;
end;

procedure TPipeHeartbeatTests.PtLocal_IgnoraHeartbeatIntervalMs;
var
  LPipeName: string;
begin
  // ptLocal ignora HeartbeatIntervalMs (mesma regra de KeepAliveSeconds): uma
  // sessao ociosa nos dois sentidos NAO pode cair so' por causa dele.
  LPipeName := UniquePipeName;
  FServer := TPipeServer.Create(LPipeName, ptLocal);
  FServer.HeartbeatIntervalMs := 100; // se fosse respeitado, mataria em ~200ms
  FServer.OnClientDisconnected := OnSrvClientDisconnected;
  FServer.Listen;
  FClient := TPipeClient.Create(LPipeName, ptLocal);
  FClient.HeartbeatIntervalMs := 100;
  FClient.OnDisconnected := OnCliDisconnected;
  FClient.Connect(3000);
  AssertTrue('ptLocal nao devia cair por causa de HeartbeatIntervalMs',
    WaitStill(FSrvDiscCount, 1, 600));
  AssertTrue('cliente devia continuar conectado', FClient.Connected);
end;

procedure TPipeHeartbeatTests.StopEDisconnect_ComHeartbeatAtivo_TerminamRapido;
var
  T0: UInt64;
begin
  FServer := TPipeServer.Create(UniqueTcpAddress, ptTcp);
  FServer.HeartbeatIntervalMs := 200;
  FServer.OnClientDisconnected := OnSrvClientDisconnected;
  FServer.Listen;
  FClient := TPipeClient.Create(FServer.Address, ptTcp);
  FClient.HeartbeatIntervalMs := 200;
  FClient.OnDisconnected := OnCliDisconnected;
  FClient.Connect(3000);
  Sleep(50); // deixa as duas heartbeat threads (servidor e cliente) de pe

  T0 := PipeTickMs;
  FServer.Stop;
  AssertTrue('Stop com heartbeat ativo demorou demais (deadlock na StopHeartbeat?)',
    PipeTickMs - T0 < 2000);

  T0 := PipeTickMs;
  FClient.Disconnect;
  AssertTrue('Disconnect com heartbeat ativo demorou demais (deadlock na StopHeartbeat?)',
    PipeTickMs - T0 < 2000);
end;

initialization
  RegisterTest(TPipeHeartbeatTests);

end.
