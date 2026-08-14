unit Pipes.PeerAddressTests;

{ Testes de integracao de TPipeServer.TryClientAddress (endereco IP:porta do
  par, ver docs/ARQUITETURA.md e o cabecalho de TryPeerAddress em
  Pipes.Transport.pas): so' existe endereco de rede em ptTcp/ptTls, nunca em
  ptLocal (Named Pipe/UDS), e o endereco sobrevive a saida do cliente do mesmo
  jeito que TryClientIdentity — mesmo motivo: responder "de onde veio quem
  saiu?" dentro de OnClientDisconnected. Versao DUnitX/Delphi; espelha a
  versao FPCUnit em tests/Integration/fpc. }

interface

uses
  DUnitX.TestFramework,
  SysUtils,
  Pipes.Types,
  Pipes.Threading,
  Pipes.Server,
  Pipes.Client;

type
  [TestFixture]
  TPipePeerAddressTests = class
  private
    FServer: TPipeServer;
    FClient: TPipeClient;
    FDisconnected: Integer; // atomico
    procedure OnSrvDisconnected(Sender: TObject; AConnId: TPipeConnectionId);
    function WaitFlag(var AFlag: Integer; ATimeoutMs: Cardinal): Boolean;
  public
    [Setup] procedure SetUp;
    [TearDown] procedure TearDown;
  published
    [Test] procedure Tcp_ClienteEstabelecido_DevolveIpEPorta;
    [Test] procedure Local_SemEnderecoDeRede_DevolveFalse;
    [Test] procedure ConexaoInexistente_DevolveFalse;
    [Test] procedure Tcp_SobreviveAoDisconnect;
  end;

implementation

// Length() e' NativeInt no Win64 e AreEqual<T> nao infere T com argumentos de
// tipos diferentes (E2532) — mesmo motivo do helper em Pipes.StatsTests.
procedure EqualInt(AExpected, AActual: Integer);
begin
  Assert.AreEqual(AExpected, AActual);
end;

var
  GNameSeq: Integer;

function UniquePipeName: string;
begin
  Result := 'pipes_faa_peeraddr_' + IntToStr(Int64(PipeTickMs)) + '_' +
    IntToStr(PipeAtomicInc(GNameSeq));
end;

// Mesmo esquema de Pipes.TlsTests.UniqueAddr: faixa deslocada pelo tick para
// reduzir colisao entre execucoes.
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
  FDisconnected := 0;
end;

procedure TPipePeerAddressTests.TearDown;
begin
  FreeAndNil(FClient);
  FreeAndNil(FServer);
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
  Assert.IsTrue(WaitClientCount(FServer, 1, 3000),
    'servidor nao marcou a conexao como estabelecida a tempo');

  LIds := FServer.ClientIds;
  EqualInt(1, Length(LIds));
  Assert.IsTrue(FServer.TryClientAddress(LIds[0], LAddress),
    'ptTcp devia ter endereco de rede');
  Assert.IsTrue(Pos('127.0.0.1:', LAddress) = 1,
    'endereco devia comecar com o IP de loopback: ' + LAddress);
  // A porta e' EFEMERA (o SO escolhe): so' confere que ha um numero > 0 apos
  // o ':', nao um valor fixo.
  LColon := Pos(':', LAddress);
  LPort := StrToIntDef(Copy(LAddress, LColon + 1, MaxInt), -1);
  Assert.IsTrue(LPort > 0, 'porta invalida em ' + LAddress);
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
  Assert.IsTrue(WaitClientCount(FServer, 1, 3000),
    'servidor nao marcou a conexao como estabelecida a tempo');

  LIds := FServer.ClientIds;
  EqualInt(1, Length(LIds));
  Assert.IsFalse(FServer.TryClientAddress(LIds[0], LAddress),
    'ptLocal (Named Pipe/UDS) nao tem endereco IP');
  Assert.AreEqual('', LAddress);
end;

procedure TPipePeerAddressTests.ConexaoInexistente_DevolveFalse;
var
  LAddress: string;
begin
  FServer := TPipeServer.Create(UniquePipeName);
  FServer.Listen;
  Assert.IsFalse(FServer.TryClientAddress(999999, LAddress),
    'conexao inexistente devia devolver False');
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
  Assert.IsTrue(WaitClientCount(FServer, 1, 3000),
    'servidor nao marcou a conexao como estabelecida a tempo');

  LIds := FServer.ClientIds;
  EqualInt(1, Length(LIds));
  LId := LIds[0];
  Assert.IsTrue(FServer.TryClientAddress(LId, LAddress));

  FClient.Disconnect;
  Assert.IsTrue(WaitFlag(FDisconnected, 3000),
    'OnClientDisconnected nao disparou a tempo');

  // Mesmo criterio de TryClientIdentity: o endereco continua consultavel
  // DEPOIS da saida, para responder "de onde veio quem saiu?" dentro do
  // proprio handler de OnClientDisconnected.
  Assert.IsTrue(FServer.TryClientAddress(LId, LAddress),
    'endereco devia sobreviver a saida do cliente');
  Assert.IsTrue(Pos('127.0.0.1:', LAddress) = 1);
end;

initialization
  TDUnitX.RegisterTestFixture(TPipePeerAddressTests);

end.
