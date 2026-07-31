unit Pipes.FailoverTests;

{$mode delphi}{$H+}

{ Testes de FailoverAddresses/ActiveAddress (TPipeClient): Connect tentando
  varios enderecos, reconexao automatica migrando para um alternativo quando o
  primario cai, e o primario voltando a ser preferido depois de uma sessao
  DURAVEL num alternativo (nao so' "avanca pro proximo" - ver o cabecalho de
  Pipes.Client.pas). Versao FPCUnit; espelha a versao DUnitX em
  tests/Integration. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  SyncObjs,
  Pipes.Types,
  Pipes.Threading,
  Pipes.Server,
  Pipes.Client;

type
  TPipeFailoverTests = class(TTestCase)
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
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure SemFailoverAddresses_ActiveAddressEIgualAAddress;
    procedure Connect_PrimarioVivo_PrefereAddress;
    procedure Connect_PrimarioMorto_UsaFailover;
    procedure Reconexao_PrimarioCaiPermanente_MigraParaBackup;
    procedure Reconexao_SessaoDuravelNoBackup_VoltaAoPrimarioDepois;
    procedure MaxReconnectAttempts_ContaTentativasContraQualquerEndereco;
  end;

implementation

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
  inherited;
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
  inherited;
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
  AssertEquals(LName, FClient.ActiveAddress);
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

  AssertEquals(LPrimario, FClient.ActiveAddress);
  AssertTrue(WaitClientCount(FPrimary, 1, 2000));
  AssertEquals(0, FBackup2.ClientCount);
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

  AssertEquals(LBackup, FClient.ActiveAddress);
  AssertTrue(WaitClientCount(FBackup2, 1, 2000));
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
  AssertTrue('conexao inicial nao disparou', WaitCount(FCliConnCount, 1, 3000));

  FPrimary.Stop; // cai e nao volta

  // 1a tentativa de reabrir mira o primario (morto, consome ReconnectDelayMs)
  // e avanca pro backup; a seguinte mira o backup e da certo.
  AssertTrue('nao migrou para o backup apos o primario cair',
    WaitCount(FCliConnCount, 2, 5000));
  AssertEquals(LBackup, FClient.ActiveAddress);
  AssertTrue(WaitClientCount(FBackup2, 1, 2000));
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
  AssertTrue(WaitCount(FCliConnCount, 1, 3000));

  FPrimary.Stop; // 1o. episodio de falha: migra para o 1o alternativo (backup2)
  AssertTrue('nao migrou para backup2 apos o primario cair',
    WaitCount(FCliConnCount, 2, 5000));
  AssertEquals(LBackup2Name, FClient.ActiveAddress);

  // Sessao DURAVEL no backup2 (bem mais que ReconnectDelayMs): o proximo
  // episodio de falha deve preferir o PRIMARIO de novo, e nao so' "avancar"
  // para backup3 - por isso o primario volta ao ar antes do backup2 cair.
  Sleep(700);
  FreeAndNil(FPrimary); // Stop ja' parou, mas nao libera - a instancia antiga vazaria
  FPrimary := TPipeServer.Create(LPrimario);
  FPrimary.Listen;

  FBackup2.Stop; // 2o. episodio de falha, a partir de uma sessao DURAVEL
  AssertTrue('nao reconectou apos o backup2 cair',
    WaitCount(FCliConnCount, 3, 5000));
  AssertEquals(
    'sessao duravel deveria preferir o primario, nao avancar para o proximo da lista',
    LPrimario, FClient.ActiveAddress);
  AssertEquals(0, FBackup3.ClientCount);
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
  AssertTrue(WaitCount(FCliConnCount, 1, 3000));

  FPrimary.Stop; // cai; o backup nunca esteve no ar - as 4 tentativas falham

  // 4 tentativas a 150ms cabem em ~600ms; folga larga para desistir e parar.
  Sleep(2000);
  FLock.Enter;
  try
    AssertTrue('esperava o erro de reconexao esgotada, veio: ' + FLastError,
      Pos('tentativas', FLastError) > 0);
  finally
    FLock.Leave;
  end;
  AssertEquals(1, FCliConnCount); // nunca voltou a conectar em endereco nenhum
end;

initialization
  RegisterTest(TPipeFailoverTests);

end.
