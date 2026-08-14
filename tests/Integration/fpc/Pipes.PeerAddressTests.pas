unit Pipes.PeerAddressTests;

{$mode delphi}{$H+}

{ Testes de integracao de TPipeServer.TryClientAddress (endereco IP:porta do
  par, ver docs/ARQUITETURA.md e o cabecalho de TryPeerAddress em
  Pipes.Transport.pas): so' existe endereco de rede em ptTcp/ptTls, nunca em
  ptLocal (Named Pipe/UDS), e o endereco sobrevive a saida do cliente do mesmo
  jeito que TryClientIdentity — mesmo motivo: responder "de onde veio quem
  saiu?" dentro de OnClientDisconnected. Versao FPCUnit; espelha a versao
  DUnitX em tests/Integration. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  Pipes.Types,
  Pipes.Threading,
  Pipes.Server,
  Pipes.Client;

type
  TPipePeerAddressTests = class(TTestCase)
  private
    FServer: TPipeServer;
    FClient: TPipeClient;
    FDisconnected: Integer; // atomico
    procedure OnSrvDisconnected(Sender: TObject; AConnId: TPipeConnectionId);
    function WaitFlag(var AFlag: Integer; ATimeoutMs: Cardinal): Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure Tcp_ClienteEstabelecido_DevolveIpEPorta;
    procedure Local_SemEnderecoDeRede_DevolveFalse;
    procedure ConexaoInexistente_DevolveFalse;
    procedure Tcp_SobreviveAoDisconnect;
  end;

implementation

var
  GNameSeq: Integer;

function UniquePipeName: string;
begin
  Result := 'pipes_faa_peeraddr_' + IntToStr(Int64(PipeTickMs)) + '_' +
    IntToStr(PipeAtomicInc(GNameSeq));
end;

function UniqueTcpAddress: string;
begin
  Result := '127.0.0.1:' + IntToStr(25000 + (Int64(PipeTickMs) mod 9000) +
    PipeAtomicInc(GNameSeq));
end;

// Connect() devolve assim que o CLIENTE se considera conectado; o servidor so
// marca FEstablished (o que ClientIds/ClientCount exigem) depois, na propria
// reader thread (PublishEstablished, apos o Handshake). Sem esperar aqui,
// ClientIds logo apos Connect e' uma corrida real, nao um bug da lib.
function WaitClientCount(AServer: TPipeServer; AExpected: Integer;
  ATimeoutMs: Cardinal): Boolean;
var
  LDeadline: UInt64;
begin
  LDeadline := PipeTickMs + ATimeoutMs;
  while (AServer.ClientCount < AExpected) and (PipeTickMs < LDeadline) do
    Sleep(5);
  Result := AServer.ClientCount >= AExpected;
end;

{ TPipePeerAddressTests }

procedure TPipePeerAddressTests.SetUp;
begin
  inherited;
  FDisconnected := 0;
end;

procedure TPipePeerAddressTests.TearDown;
begin
  FreeAndNil(FClient);
  FreeAndNil(FServer);
  inherited;
end;

procedure TPipePeerAddressTests.OnSrvDisconnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  PipeAtomicInc(FDisconnected);
end;

function TPipePeerAddressTests.WaitFlag(var AFlag: Integer;
  ATimeoutMs: Cardinal): Boolean;
var
  LDeadline: UInt64;
begin
  LDeadline := PipeTickMs + ATimeoutMs;
  while (PipeAtomicGet(AFlag) = 0) and (PipeTickMs < LDeadline) do
    Sleep(5);
  Result := PipeAtomicGet(AFlag) <> 0;
end;

procedure TPipePeerAddressTests.Tcp_ClienteEstabelecido_DevolveIpEPorta;
var
  LIds: TArray<TPipeConnectionId>;
  LAddress: string;
  LColon: Integer;
  LPort: Integer;
begin
  FServer := TPipeServer.Create(UniqueTcpAddress, ptTcp);
  FServer.Listen;
  FClient := TPipeClient.Create(FServer.Address, ptTcp);
  FClient.Connect(3000);
  AssertTrue('servidor nao marcou a conexao como estabelecida a tempo',
    WaitClientCount(FServer, 1, 3000));

  LIds := FServer.ClientIds;
  AssertEquals(1, Length(LIds));
  AssertTrue('ptTcp devia ter endereco de rede',
    FServer.TryClientAddress(LIds[0], LAddress));
  AssertTrue('endereco devia comecar com o IP de loopback: ' + LAddress,
    Pos('127.0.0.1:', LAddress) = 1);
  LColon := Pos(':', LAddress);
  LPort := StrToIntDef(Copy(LAddress, LColon + 1, MaxInt), -1);
  AssertTrue('porta invalida em ' + LAddress, LPort > 0);
end;

procedure TPipePeerAddressTests.Local_SemEnderecoDeRede_DevolveFalse;
var
  LIds: TArray<TPipeConnectionId>;
  LAddress: string;
begin
  FServer := TPipeServer.Create(UniquePipeName); // ptLocal (padrao)
  FServer.Listen;
  FClient := TPipeClient.Create(FServer.Address);
  FClient.Connect(3000);
  AssertTrue('servidor nao marcou a conexao como estabelecida a tempo',
    WaitClientCount(FServer, 1, 3000));

  LIds := FServer.ClientIds;
  AssertEquals(1, Length(LIds));
  AssertFalse('ptLocal (Named Pipe/UDS) nao tem endereco IP',
    FServer.TryClientAddress(LIds[0], LAddress));
  AssertEquals('', LAddress);
end;

procedure TPipePeerAddressTests.ConexaoInexistente_DevolveFalse;
var
  LAddress: string;
begin
  FServer := TPipeServer.Create(UniquePipeName);
  FServer.Listen;
  AssertFalse('conexao inexistente devia devolver False',
    FServer.TryClientAddress(999999, LAddress));
end;

procedure TPipePeerAddressTests.Tcp_SobreviveAoDisconnect;
var
  LIds: TArray<TPipeConnectionId>;
  LId: TPipeConnectionId;
  LAddress: string;
begin
  FServer := TPipeServer.Create(UniqueTcpAddress, ptTcp);
  FServer.OnClientDisconnected := OnSrvDisconnected;
  FServer.Listen;
  FClient := TPipeClient.Create(FServer.Address, ptTcp);
  FClient.Connect(3000);
  AssertTrue('servidor nao marcou a conexao como estabelecida a tempo',
    WaitClientCount(FServer, 1, 3000));

  LIds := FServer.ClientIds;
  AssertEquals(1, Length(LIds));
  LId := LIds[0];
  AssertTrue(FServer.TryClientAddress(LId, LAddress));

  FClient.Disconnect;
  AssertTrue('OnClientDisconnected nao disparou a tempo',
    WaitFlag(FDisconnected, 3000));

  AssertTrue('endereco devia sobreviver a saida do cliente',
    FServer.TryClientAddress(LId, LAddress));
  AssertTrue(Pos('127.0.0.1:', LAddress) = 1);
end;

initialization
  RegisterTest(TPipePeerAddressTests);

end.
