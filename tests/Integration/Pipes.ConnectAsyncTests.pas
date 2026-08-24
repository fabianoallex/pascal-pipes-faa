unit Pipes.ConnectAsyncTests;

{ Testes de ConnectAsync/Connecting (TPipeClient): a primeira conexao tentada
  em segundo plano, para o caso que Connect nao cobre (o app sobe ANTES do
  servidor) e que AutoReconnect tambem nao (ele so' entra depois de uma sessao
  ter existido e caido).

  O que cada teste guarda contra esta no comentario dele; os dois que merecem
  atencao sao o de cancelamento (o teto e' UMA tentativa, nao zero - ver
  ConnectAsync_CanceladoPorDisconnect_...) e o de convivencia com
  AutoReconnect, que e' onde um FConnectingAsync vazado apareceria.

  Versao DUnitX; espelha a versao FPCUnit em tests/Integration/fpc. }

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
  TPipeConnectAsyncTests = class
  private
    FServer, FBackup: TPipeServer;
    FClient: TPipeClient;
    FLock: TCriticalSection;
    FCliConnCount: Integer; // atomico
    FErrCount: Integer;     // atomico
    FLastError: string;     // sob FLock
    procedure OnCliConnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnCliError(Sender: TObject; AConnId: TPipeConnectionId;
      const AError: string);
    // Alvos de Assert.WillRaise (metodos de objeto: a lib nao usa metodos
    // anonimos, ver CLAUDE.md).
    procedure DoSetAddress;
    procedure DoSetTransport;
    function LastError: string;
    function WaitCount(var ACounter: Integer; AExpected: Integer;
      ATimeoutMs: Cardinal): Boolean;
    function WaitClientCount(AServer: TPipeServer; AExpected: Integer;
      ATimeoutMs: Cardinal): Boolean;
    /// Connecting so' cai DEPOIS de OnConnected (quem limpa o flag e' a thread
    /// de reconexao, ja fora de TryReopenSession) - por isso a espera, em vez
    /// de um assert seco logo apos o evento.
    function WaitNotConnecting(ATimeoutMs: Cardinal): Boolean;
  public
    [Setup] procedure SetUp;
    [TearDown] procedure TearDown;
  published
    [Test] procedure ConnectAsync_ServidorJaNoAr_ConectaENotifica;
    [Test] procedure ConnectAsync_ServidorSobeDepois_ConectaQuandoAparece;
    [Test] procedure ConnectAsync_ServidorNuncaAparece_EsgotaComMensagemDeConexaoInicial;
    [Test] procedure ConnectAsync_CanceladoPorDisconnect_ParaDeTentar;
    [Test] procedure ConnectAsync_ChamadoDeNovoEnquantoEmVoo_ReiniciaSemDuplicar;
    [Test] procedure ConnectAsync_ComFailoverAddresses_MigraParaBackupSemPrimario;
    [Test] procedure ConnectAsync_ComAutoReconnect_ContinuaReconectandoDepois;
    [Test] procedure Connecting_SemChamarConnectAsync_PermaneceFalse;
    [Test] procedure ConnectAsync_EmVoo_ImpedeTrocarTransportOuAddress;
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
  Result := 'pipes_faa_connasync_' + IntToStr(Int64(PipeTickMs)) + '_' +
    IntToStr(PipeAtomicInc(GNameSeq)) + '_' + ASufixo;
end;

{ TPipeConnectAsyncTests }

procedure TPipeConnectAsyncTests.SetUp;
begin
  FLock := TCriticalSection.Create;
  FCliConnCount := 0;
  FErrCount := 0;
  FLastError := '';
end;

procedure TPipeConnectAsyncTests.TearDown;
begin
  FreeAndNil(FClient); // Disconnect no destructor (cancela ConnectAsync em voo)
  FreeAndNil(FServer); // Stop no destructor
  FreeAndNil(FBackup);
  FreeAndNil(FLock);
end;

procedure TPipeConnectAsyncTests.OnCliConnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  PipeAtomicInc(FCliConnCount);
end;

procedure TPipeConnectAsyncTests.OnCliError(Sender: TObject;
  AConnId: TPipeConnectionId; const AError: string);
begin
  FLock.Enter;
  try
    FLastError := AError;
  finally
    FLock.Leave;
  end;
  PipeAtomicInc(FErrCount); // depois de gravar: quem acorda no contador ja le' a mensagem
end;

function TPipeConnectAsyncTests.LastError: string;
begin
  FLock.Enter;
  try
    Result := FLastError;
  finally
    FLock.Leave;
  end;
end;

procedure TPipeConnectAsyncTests.DoSetAddress;
begin
  FClient.Address := UniquePipeName('trocado');
end;

procedure TPipeConnectAsyncTests.DoSetTransport;
begin
  FClient.Transport := ptTcp;
end;

function TPipeConnectAsyncTests.WaitCount(var ACounter: Integer;
  AExpected: Integer; ATimeoutMs: Cardinal): Boolean;
var
  LDeadline: UInt64;
begin
  LDeadline := PipeTickMs + ATimeoutMs;
  while (PipeAtomicGet(ACounter) < AExpected) and (PipeTickMs < LDeadline) do
    Sleep(5);
  Result := PipeAtomicGet(ACounter) >= AExpected;
end;

function TPipeConnectAsyncTests.WaitClientCount(AServer: TPipeServer;
  AExpected: Integer; ATimeoutMs: Cardinal): Boolean;
var
  LDeadline: UInt64;
begin
  LDeadline := PipeTickMs + ATimeoutMs;
  while (AServer.ClientCount < AExpected) and (PipeTickMs < LDeadline) do
    Sleep(5);
  Result := AServer.ClientCount >= AExpected;
end;

function TPipeConnectAsyncTests.WaitNotConnecting(ATimeoutMs: Cardinal): Boolean;
var
  LDeadline: UInt64;
begin
  LDeadline := PipeTickMs + ATimeoutMs;
  while FClient.Connecting and (PipeTickMs < LDeadline) do
    Sleep(5);
  Result := not FClient.Connecting;
end;

procedure TPipeConnectAsyncTests.ConnectAsync_ServidorJaNoAr_ConectaENotifica;
var
  LName: string;
begin
  LName := UniquePipeName('ja_no_ar');
  FServer := TPipeServer.Create(LName);
  FServer.Listen;

  FClient := TPipeClient.Create(LName);
  FClient.ReconnectDelayMs := 300;
  FClient.OnConnected := OnCliConnected;
  FClient.ConnectAsync; // volta na hora, mesmo com o servidor ja disponivel

  Assert.IsTrue(WaitCount(FCliConnCount, 1, 5000), 'OnConnected nao disparou');
  Assert.IsTrue(FClient.Connected, 'deveria estar conectado');
  Assert.IsTrue(WaitNotConnecting(2000), 'Connecting deveria ter caido');
  Assert.IsTrue(WaitClientCount(FServer, 1, 2000));
end;

procedure TPipeConnectAsyncTests.ConnectAsync_ServidorSobeDepois_ConectaQuandoAparece;
var
  LName: string;
begin
  // O teste central da feature: ninguem escutando quando o cliente pede a
  // conexao. Connect() sincrono falharia aqui, e AutoReconnect nao entraria
  // (nunca houve sessao para cair).
  LName := UniquePipeName('sobe_depois');
  FClient := TPipeClient.Create(LName);
  FClient.ReconnectDelayMs := 300;
  FClient.OnConnected := OnCliConnected;
  FClient.ConnectAsync;

  Assert.IsTrue(FClient.Connecting, 'Connecting deveria ser True logo apos a chamada');
  Assert.IsFalse(FClient.Connected, 'nao ha servidor: nao pode estar conectado');
  Sleep(400); // pelo menos uma tentativa fracassa antes de o servidor existir
  EqualInt(0, FCliConnCount);

  FServer := TPipeServer.Create(LName);
  FServer.Listen;

  Assert.IsTrue(WaitCount(FCliConnCount, 1, 5000),
    'nao conectou depois de o servidor subir');
  Assert.IsTrue(FClient.Connected);
  Assert.IsTrue(WaitNotConnecting(2000), 'Connecting deveria ter caido');
  Assert.IsTrue(WaitClientCount(FServer, 1, 2000));
end;

procedure TPipeConnectAsyncTests.ConnectAsync_ServidorNuncaAparece_EsgotaComMensagemDeConexaoInicial;
var
  LName: string;
begin
  LName := UniquePipeName('nunca_aparece'); // ninguem escuta, nunca
  FClient := TPipeClient.Create(LName);
  FClient.ReconnectDelayMs := 200;
  FClient.MaxReconnectAttempts := 3; // ~600ms de tentativas
  FClient.OnConnected := OnCliConnected;
  FClient.OnError := OnCliError;
  FClient.ConnectAsync;

  Assert.IsTrue(WaitCount(FErrCount, 1, 5000), 'nao avisou o esgotamento');
  // A mensagem muda com o contexto: "reconexao esgotada" soaria errado para
  // quem nunca chegou a ter uma sessao.
  Assert.IsTrue(Pos('conexao inicial', LastError) > 0,
    'esperava a mensagem de conexao INICIAL, veio: ' + LastError);
  Assert.IsTrue(WaitNotConnecting(2000), 'Connecting deveria ter caido ao desistir');
  Assert.IsFalse(FClient.Connected);
  EqualInt(0, FCliConnCount); // nunca conectou
end;

procedure TPipeConnectAsyncTests.ConnectAsync_CanceladoPorDisconnect_ParaDeTentar;
var
  LName: string;
  LT0: UInt64;
  LDecorrido: UInt64;
begin
  LName := UniquePipeName('cancelado'); // ninguem escuta
  FClient := TPipeClient.Create(LName);
  FClient.ReconnectDelayMs := 600;
  FClient.MaxReconnectAttempts := 0; // infinitas: so' o Disconnect para isto
  FClient.OnConnected := OnCliConnected;
  FClient.ConnectAsync;
  Assert.IsTrue(FClient.Connecting);

  Sleep(100); // no meio da PRIMEIRA tentativa
  LT0 := PipeTickMs;
  FClient.Disconnect;
  LDecorrido := PipeTickMs - LT0;

  // O teto e' UMA tentativa em curso, nao zero: nenhum backend de transporte
  // cancela um connect em progresso, e Disconnect herda o mesmo trade-off que
  // ja aceita para a reconexao automatica (ver WaitReconnectDone). O que este
  // teste prova e' que ele PARA - sem o cancelamento o laco seria infinito.
  Assert.IsTrue(LDecorrido < 2500,
    'Disconnect demorou ' + IntToStr(Int64(LDecorrido)) +
    ' ms; esperava no maximo uma tentativa em curso');
  Assert.IsFalse(FClient.Connecting, 'Connecting deveria ser False apos Disconnect');
  Assert.IsFalse(FClient.Connected);

  // E parou de verdade: nada mais acontece depois.
  Sleep(1500);
  Assert.IsFalse(FClient.Connecting, 'voltou a tentar depois do Disconnect');
  EqualInt(0, FCliConnCount);
end;

procedure TPipeConnectAsyncTests.ConnectAsync_ChamadoDeNovoEnquantoEmVoo_ReiniciaSemDuplicar;
var
  LName: string;
begin
  LName := UniquePipeName('rechamado');
  FClient := TPipeClient.Create(LName);
  FClient.ReconnectDelayMs := 300;
  FClient.OnConnected := OnCliConnected;
  FClient.ConnectAsync;
  Sleep(400); // deixa a primeira tentativa fracassar

  FClient.ConnectAsync; // cancela a anterior e recomeca
  Assert.IsTrue(FClient.Connecting);

  FServer := TPipeServer.Create(LName);
  FServer.Listen;
  Assert.IsTrue(WaitCount(FCliConnCount, 1, 5000), 'a segunda chamada nao conectou');
  Assert.IsTrue(WaitClientCount(FServer, 1, 2000));

  // Uma thread orfa da PRIMEIRA chamada abriria uma segunda conexao no
  // servidor (e um segundo OnConnected) - e' isto que a rechamada nao pode
  // deixar acontecer.
  Sleep(700);
  EqualInt(1, FCliConnCount);
  EqualInt(1, FServer.ClientCount);
end;

procedure TPipeConnectAsyncTests.ConnectAsync_ComFailoverAddresses_MigraParaBackupSemPrimario;
var
  LPrimario, LBackup: string;
begin
  LPrimario := UniquePipeName('primario'); // ninguem escuta
  LBackup := UniquePipeName('backup');
  FBackup := TPipeServer.Create(LBackup);
  FBackup.Listen;

  FClient := TPipeClient.Create(LPrimario);
  FClient.FailoverAddresses := [LBackup];
  FClient.ReconnectDelayMs := 300;
  FClient.OnConnected := OnCliConnected;
  FClient.ConnectAsync;

  // 1a tentativa mira o primario (morto, consome ReconnectDelayMs) e avanca;
  // a 2a mira o backup e conecta - a MESMA regra da reconexao automatica.
  Assert.IsTrue(WaitCount(FCliConnCount, 1, 5000), 'nao alcancou o backup');
  Assert.AreEqual(LBackup, FClient.ActiveAddress);
  Assert.IsTrue(WaitNotConnecting(2000));
  Assert.IsTrue(WaitClientCount(FBackup, 1, 2000));
end;

procedure TPipeConnectAsyncTests.ConnectAsync_ComAutoReconnect_ContinuaReconectandoDepois;
var
  LName: string;
begin
  // Um FConnectingAsync que nao fosse limpo (ou que fosse limpo cedo demais)
  // apareceria AQUI: depois de o ConnectAsync cumprir o seu papel, o ciclo de
  // vida normal do AutoReconnect precisa continuar intacto.
  LName := UniquePipeName('com_autoreconnect');
  FServer := TPipeServer.Create(LName);
  FServer.Listen;

  FClient := TPipeClient.Create(LName);
  FClient.AutoReconnect := True;
  FClient.ReconnectDelayMs := 300;
  FClient.OnConnected := OnCliConnected;
  FClient.ConnectAsync;
  Assert.IsTrue(WaitCount(FCliConnCount, 1, 5000), 'conexao inicial nao ocorreu');
  Assert.IsTrue(WaitNotConnecting(2000),
    'Connecting deveria cair assim que a sessao subiu');

  Sleep(700); // sessao DURAVEL (bem mais que ReconnectDelayMs)
  FreeAndNil(FServer); // derruba a sessao...
  FServer := TPipeServer.Create(LName);
  FServer.Listen;      // ...e volta no mesmo endereco

  Assert.IsTrue(WaitCount(FCliConnCount, 2, 6000),
    'AutoReconnect nao reconectou depois de o ConnectAsync ter terminado');
  Assert.IsTrue(FClient.Connected);
  // Reconexao automatica nao e' ConnectAsync: Connecting continua False.
  Assert.IsFalse(FClient.Connecting,
    'Connecting fala apenas de ConnectAsync, nao de reconexao automatica');
  Assert.IsTrue(WaitClientCount(FServer, 1, 2000));
end;

procedure TPipeConnectAsyncTests.Connecting_SemChamarConnectAsync_PermaneceFalse;
var
  LName: string;
begin
  LName := UniquePipeName('sanidade');
  FServer := TPipeServer.Create(LName);
  FServer.Listen;

  FClient := TPipeClient.Create(LName);
  Assert.IsFalse(FClient.Connecting, 'cliente recem-criado nao esta conectando');

  FClient.Connect(3000); // sincrono: nao liga Connecting em momento nenhum
  Assert.IsTrue(FClient.Connected);
  Assert.IsFalse(FClient.Connecting, 'Connect sincrono nao pode ligar Connecting');

  FClient.Disconnect;
  Assert.IsFalse(FClient.Connecting);
  Assert.IsFalse(FClient.Connected);
end;

procedure TPipeConnectAsyncTests.ConnectAsync_EmVoo_ImpedeTrocarTransportOuAddress;
var
  LName: string;
begin
  // Com Connect() sincrono esta janela nem existe (o chamador fica bloqueado);
  // com ConnectAsync ele volta na hora, entao a trava de configuracao precisa
  // valer tambem durante a tentativa - senao a proxima tentativa miraria outro
  // servidor sem ninguem ter pedido.
  LName := UniquePipeName('em_voo'); // ninguem escuta: fica tentando
  FClient := TPipeClient.Create(LName);
  FClient.ReconnectDelayMs := 300;
  FClient.ConnectAsync;
  Assert.IsTrue(FClient.Connecting);

  Assert.WillRaise(DoSetAddress, EPipeError, 'Address nao pode mudar em voo');
  Assert.WillRaise(DoSetTransport, EPipeError, 'Transport nao pode mudar em voo');
  Assert.AreEqual(LName, FClient.Address, 'Address nao pode ter mudado');

  FClient.Disconnect; // sem tentativa em voo, a configuracao volta a ser livre
  Assert.IsFalse(FClient.Connecting);
  DoSetTransport;
  Assert.IsTrue(FClient.Transport = ptTcp);
end;

initialization
  TDUnitX.RegisterTestFixture(TPipeConnectAsyncTests);

end.
