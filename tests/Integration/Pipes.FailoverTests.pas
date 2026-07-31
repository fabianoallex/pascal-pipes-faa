unit Pipes.FailoverTests;

{ Testes de FailoverAddresses/ActiveAddress (TPipeClient): Connect tentando
  varios enderecos, reconexao automatica migrando para um alternativo quando o
  primario cai, e o primario voltando a ser preferido depois de uma sessao
  DURAVEL num alternativo (nao so' "avanca pro proximo" - ver o cabecalho de
  Pipes.Client.pas). Versao DUnitX; espelha a versao FPCUnit em
  tests/Integration/fpc. }

interface

uses
  DUnitX.TestFramework,
  SysUtils,
  SyncObjs,
  Pipes.Types,
  Pipes.Threading,
  Pipes.Server,
  Pipes.Client;

type
  [TestFixture]
  TPipeFailoverTests = class
  private
    FPrimary, FBackup2, FBackup3: TPipeServer;
    FClient: TPipeClient;
    FLock: TCriticalSection;
    FCliConnCount: Integer; // atomico
    FLastError: string;     // sob FLock
    procedure OnCliConnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnCliError(Sender: TObject; AConnId: TPipeConnectionId;
      const AError: string);
    function WaitCount(var ACounter: Integer; AExpected: Integer;
      ATimeoutMs: Cardinal): Boolean;
    /// ClientCount so' conta conexoes ESTABELECIDAS (depois do proprio
    /// OnClientConnected do servidor disparar) - fica um passo atras do
    /// retorno de Client.Connect, que so' depende do lado do cliente.
    function WaitClientCount(AServer: TPipeServer; AExpected: Integer;
      ATimeoutMs: Cardinal): Boolean;
  public
    [Setup] procedure SetUp;
    [TearDown] procedure TearDown;
  published
    [Test] procedure SemFailoverAddresses_ActiveAddressEIgualAAddress;
    [Test] procedure Connect_PrimarioVivo_PrefereAddress;
    [Test] procedure Connect_PrimarioMorto_UsaFailover;
    [Test] procedure Reconexao_PrimarioCaiPermanente_MigraParaBackup;
    [Test] procedure Reconexao_SessaoDuravelNoBackup_VoltaAoPrimarioDepois;
    [Test] procedure MaxReconnectAttempts_ContaTentativasContraQualquerEndereco;
  end;

implementation

procedure EqualInt(AExpected, AActual: Integer);
begin
  Assert.AreEqual(AExpected, AActual);
end;

var
  GNameSeq: Integer;

function UniquePipeName(const ASufixo: string): string;
begin
  Result := 'pipes_faa_failover_' + IntToStr(Int64(PipeTickMs)) + '_' +
    IntToStr(PipeAtomicInc(GNameSeq)) + '_' + ASufixo;
end;

{ TPipeFailoverTests }

procedure TPipeFailoverTests.SetUp;
begin
  FLock := TCriticalSection.Create;
  FCliConnCount := 0;
  FLastError := '';
end;

procedure TPipeFailoverTests.TearDown;
begin
  FreeAndNil(FClient);  // Disconnect no destructor
  FreeAndNil(FPrimary); // Stop no destructor
  FreeAndNil(FBackup2);
  FreeAndNil(FBackup3);
  FreeAndNil(FLock);
end;

function TPipeFailoverTests.WaitCount(var ACounter: Integer;
  AExpected: Integer; ATimeoutMs: Cardinal): Boolean;
var
  LDeadline: UInt64;
begin
  LDeadline := PipeTickMs + ATimeoutMs;
  while (PipeAtomicGet(ACounter) < AExpected) and (PipeTickMs < LDeadline) do
    Sleep(5);
  Result := PipeAtomicGet(ACounter) >= AExpected;
end;

function TPipeFailoverTests.WaitClientCount(AServer: TPipeServer;
  AExpected: Integer; ATimeoutMs: Cardinal): Boolean;
var
  LDeadline: UInt64;
begin
  LDeadline := PipeTickMs + ATimeoutMs;
  while (AServer.ClientCount < AExpected) and (PipeTickMs < LDeadline) do
    Sleep(5);
  Result := AServer.ClientCount >= AExpected;
end;

procedure TPipeFailoverTests.OnCliConnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  PipeAtomicInc(FCliConnCount);
end;

procedure TPipeFailoverTests.OnCliError(Sender: TObject;
  AConnId: TPipeConnectionId; const AError: string);
begin
  FLock.Enter;
  try
    FLastError := AError;
  finally
    FLock.Leave;
  end;
end;

procedure TPipeFailoverTests.SemFailoverAddresses_ActiveAddressEIgualAAddress;
var
  LName: string;
begin
  LName := UniquePipeName('unico');
  FPrimary := TPipeServer.Create(LName);
  FPrimary.Listen;
  FClient := TPipeClient.Create(LName);
  FClient.Connect(3000);
  Assert.AreEqual(LName, FClient.ActiveAddress);
end;

procedure TPipeFailoverTests.Connect_PrimarioVivo_PrefereAddress;
var
  LPrimario, LBackup: string;
begin
  LPrimario := UniquePipeName('primario');
  LBackup := UniquePipeName('backup');
  FPrimary := TPipeServer.Create(LPrimario);
  FPrimary.Listen;
  FBackup2 := TPipeServer.Create(LBackup);
  FBackup2.Listen;

  FClient := TPipeClient.Create(LPrimario);
  FClient.FailoverAddresses := [LBackup];
  FClient.Connect(3000);

  Assert.AreEqual(LPrimario, FClient.ActiveAddress);
  Assert.IsTrue(WaitClientCount(FPrimary, 1, 2000));
  EqualInt(0, FBackup2.ClientCount);
end;

procedure TPipeFailoverTests.Connect_PrimarioMorto_UsaFailover;
var
  LPrimario, LBackup: string;
begin
  LPrimario := UniquePipeName('primario'); // ninguem escuta
  LBackup := UniquePipeName('backup');
  FBackup2 := TPipeServer.Create(LBackup);
  FBackup2.Listen;

  FClient := TPipeClient.Create(LPrimario);
  FClient.FailoverAddresses := [LBackup];
  // Orcamento dividido pelos 2 enderecos (~2s cada): sobra pro primario
  // "bater na porta" ate estourar e o backup responder na sequencia.
  FClient.Connect(4000);

  Assert.AreEqual(LBackup, FClient.ActiveAddress);
  Assert.IsTrue(WaitClientCount(FBackup2, 1, 2000));
end;

procedure TPipeFailoverTests.Reconexao_PrimarioCaiPermanente_MigraParaBackup;
var
  LPrimario, LBackup: string;
begin
  LPrimario := UniquePipeName('primario');
  LBackup := UniquePipeName('backup');
  FPrimary := TPipeServer.Create(LPrimario);
  FPrimary.Listen;
  FBackup2 := TPipeServer.Create(LBackup);
  FBackup2.Listen;

  FClient := TPipeClient.Create(LPrimario);
  FClient.FailoverAddresses := [LBackup];
  FClient.AutoReconnect := True;
  FClient.ReconnectDelayMs := 300;
  FClient.OnConnected := OnCliConnected;
  FClient.Connect(3000);
  Assert.IsTrue(WaitCount(FCliConnCount, 1, 3000), 'conexao inicial nao disparou');

  FPrimary.Stop; // cai e nao volta

  // 1a tentativa de reabrir mira o primario (morto, consome ReconnectDelayMs)
  // e avanca pro backup; a seguinte mira o backup e da certo.
  Assert.IsTrue(WaitCount(FCliConnCount, 2, 5000),
    'nao migrou para o backup apos o primario cair');
  Assert.AreEqual(LBackup, FClient.ActiveAddress);
  Assert.IsTrue(WaitClientCount(FBackup2, 1, 2000));
end;

procedure TPipeFailoverTests.Reconexao_SessaoDuravelNoBackup_VoltaAoPrimarioDepois;
var
  LPrimario, LBackup2Name, LBackup3Name: string;
begin
  LPrimario := UniquePipeName('primario');
  LBackup2Name := UniquePipeName('backup2');
  LBackup3Name := UniquePipeName('backup3');
  FPrimary := TPipeServer.Create(LPrimario);
  FPrimary.Listen;
  FBackup2 := TPipeServer.Create(LBackup2Name);
  FBackup2.Listen;
  FBackup3 := TPipeServer.Create(LBackup3Name);
  FBackup3.Listen;

  FClient := TPipeClient.Create(LPrimario);
  FClient.FailoverAddresses := [LBackup2Name, LBackup3Name];
  FClient.AutoReconnect := True;
  FClient.ReconnectDelayMs := 300;
  FClient.OnConnected := OnCliConnected;
  FClient.Connect(3000);
  Assert.IsTrue(WaitCount(FCliConnCount, 1, 3000));

  FPrimary.Stop; // 1o. episodio de falha: migra para o 1o alternativo (backup2)
  Assert.IsTrue(WaitCount(FCliConnCount, 2, 5000),
    'nao migrou para backup2 apos o primario cair');
  Assert.AreEqual(LBackup2Name, FClient.ActiveAddress);

  // Sessao DURAVEL no backup2 (bem mais que ReconnectDelayMs): o proximo
  // episodio de falha deve preferir o PRIMARIO de novo, e nao so' "avancar"
  // para backup3 - por isso o primario volta ao ar antes do backup2 cair.
  Sleep(700);
  FreeAndNil(FPrimary); // Stop ja' parou, mas nao libera - a instancia antiga vazaria
  FPrimary := TPipeServer.Create(LPrimario);
  FPrimary.Listen;

  FBackup2.Stop; // 2o. episodio de falha, a partir de uma sessao DURAVEL
  Assert.IsTrue(WaitCount(FCliConnCount, 3, 5000),
    'nao reconectou apos o backup2 cair');
  Assert.AreEqual(LPrimario, FClient.ActiveAddress,
    'sessao duravel deveria preferir o primario, nao avancar para o proximo da lista');
  EqualInt(0, FBackup3.ClientCount);
end;

procedure TPipeFailoverTests.MaxReconnectAttempts_ContaTentativasContraQualquerEndereco;
var
  LPrimario, LBackup: string;
begin
  LPrimario := UniquePipeName('primario');
  LBackup := UniquePipeName('backup'); // nunca escutado
  FPrimary := TPipeServer.Create(LPrimario);
  FPrimary.Listen;

  FClient := TPipeClient.Create(LPrimario);
  FClient.FailoverAddresses := [LBackup];
  FClient.AutoReconnect := True;
  FClient.ReconnectDelayMs := 150;
  FClient.MaxReconnectAttempts := 4; // teto COMPARTILHADO entre os 2 enderecos
  FClient.OnConnected := OnCliConnected;
  FClient.OnError := OnCliError;
  FClient.Connect(3000);
  Assert.IsTrue(WaitCount(FCliConnCount, 1, 3000));

  FPrimary.Stop; // cai; o backup nunca esteve no ar - as 4 tentativas falham

  // 4 tentativas a 150ms cabem em ~600ms; folga larga para desistir e parar.
  Sleep(2000);
  FLock.Enter;
  try
    Assert.IsTrue(Pos('tentativas', FLastError) > 0,
      'esperava o erro de reconexao esgotada, veio: ' + FLastError);
  finally
    FLock.Leave;
  end;
  EqualInt(1, FCliConnCount); // nunca voltou a conectar em endereco nenhum
end;

initialization
  TDUnitX.RegisterTestFixture(TPipeFailoverTests);

end.
