unit Pipes.TransportTests;

{ Testes de integracao do transporte (loopback em processo, sem dependencia
  externa): conexao, dados nos dois sentidos, frame NPF1 fim-a-fim, e as
  garantias anti-deadlock (Close desbloqueia Accept; CloseAbort desbloqueia
  Read; queda do par e' detectada). Usam so as fabricas de Pipes.Transport,
  entao valem para qualquer backend (Windows agora; POSIX no M4).
  Versao DUnitX/Delphi; espelha a versao FPCUnit em tests/Integration/fpc. }

interface

uses
  DUnitX.TestFramework,
  SysUtils,
  Classes,
  Pipes.Types,
  Pipes.Threading,
  Pipes.Framing,
  Pipes.Transport;

type
  [TestFixture]
  TPipeTransportTests = class
  private
    FListener: TPipeListener;
    FServerEp: TPipeEndpoint;
    FClientEp: TPipeEndpoint;
    // Sobe listener + acceptor, conecta o cliente e preenche os campos acima.
    procedure OpenLoopback;
    procedure DoConnectInexistente;
  protected
    // Parametrizam o fixture por transporte: a descendente TCP so troca estes
    // tres, e herda os testes publicados abaixo.
    function TestAddress: string; virtual;
    function MissingAddress: string; virtual;
    function TestTransport: TPipeTransport; virtual;
  public
    [TearDown] procedure TearDown;
  published
    [Test] procedure Loopback_EnviaERecebeNosDoisSentidos;
    [Test] procedure Loopback_FrameNpf1FimAFim;
    [Test] procedure Accept_DesbloqueiaComClose;
    [Test] procedure Read_DesbloqueiaComCloseAbort;
    [Test] procedure Read_DetectaQuedaDoPar;
    [Test] procedure Connect_TimeoutQuandoServidorNaoExiste;
    [Test] procedure MultiplosClientes_CadaUmComSeuEndpoint;
  end;

  { Mesma bateria sobre ptTcp (loopback 127.0.0.1). Exercita o backend
    Pipes.Transport.Tcp: no Windows, a espera Winsock com WSAEventSelect; no
    POSIX, o socket AF_INET reaproveitando o endpoint/listener de
    Pipes.Transport.Posix. }
  [TestFixture]
  TPipeTcpTransportTests = class(TPipeTransportTests)
  protected
    function TestAddress: string; override;
    function MissingAddress: string; override;
    function TestTransport: TPipeTransport; override;
  end;

implementation

// Comparacoes nao-genericas (evita E2532 com NativeInt no Win64).
procedure EqualInt(AExpected, AActual: Integer);
begin
  Assert.AreEqual(AExpected, AActual);
end;

var
  GNameSeq: Integer;

// Nome unico por teste: evita colisao entre execucoes/instancias paralelas.
function UniquePipeName: string;
begin
  Result := 'pipes_faa_test_' + IntToStr(Int64(PipeTickMs)) + '_' +
    IntToStr(PipeAtomicInc(GNameSeq));
end;

type
  { Aceita N conexoes e guarda os endpoints. }
  TAcceptThread = class(TThread)
  private
    FListener: TPipeListener;
    FAccepted: array of TPipeEndpoint;
  protected
    procedure Execute; override;
  public
    constructor Create(AListener: TPipeListener; AToAccept: Integer);
    function Accepted(AIndex: Integer): TPipeEndpoint;
  end;

  { Bloqueia num Read e registra como terminou. }
  TReadOneThread = class(TThread)
  private
    FEndpoint: TPipeEndpoint;
    FGotClosed: Integer; // atomico: 1 se levantou EPipeClosed
    FLen: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(AEndpoint: TPipeEndpoint);
    function GotClosed: Boolean;
  end;

constructor TAcceptThread.Create(AListener: TPipeListener; AToAccept: Integer);
begin
  FListener := AListener;
  SetLength(FAccepted, AToAccept);
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TAcceptThread.Execute;
var
  I: Integer;
begin
  for I := 0 to High(FAccepted) do
  begin
    FAccepted[I] := FListener.Accept;
    if FAccepted[I] = nil then
      Break; // listener fechado
  end;
end;

function TAcceptThread.Accepted(AIndex: Integer): TPipeEndpoint;
begin
  Result := FAccepted[AIndex];
end;

constructor TReadOneThread.Create(AEndpoint: TPipeEndpoint);
begin
  FEndpoint := AEndpoint;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TReadOneThread.Execute;
var
  LBuf: array[0..63] of Byte;
begin
  try
    FLen := FEndpoint.Read(LBuf, SizeOf(LBuf));
  except
    on EPipeClosed do
      PipeAtomicSet(FGotClosed, 1);
  end;
end;

function TReadOneThread.GotClosed: Boolean;
begin
  Result := PipeAtomicGet(FGotClosed) = 1;
end;

{ TPipeTransportTests }

procedure TPipeTransportTests.TearDown;
begin
  if Assigned(FListener) then
    FListener.Close;
  FreeAndNil(FClientEp);
  FreeAndNil(FServerEp);
  FreeAndNil(FListener);
end;

function TPipeTransportTests.TestAddress: string;
begin
  Result := UniquePipeName;
end;

function TPipeTransportTests.MissingAddress: string;
begin
  Result := 'pipes_faa_teste_inexistente_xq';
end;

function TPipeTransportTests.TestTransport: TPipeTransport;
begin
  Result := ptLocal;
end;

{ TPipeTcpTransportTests }

function TPipeTcpTransportTests.TestAddress: string;
begin
  // Porta nova a cada teste: evita TIME_WAIT barrar o rebind (no Windows o
  // listener nao usa SO_REUSEADDR, de proposito). A base varia por execucao
  // para nao colidir com uma rodada anterior ainda drenando.
  //
  // Faixa 20000..40000, ABAIXO da faixa efemera (49152+): acima dela o Windows
  // reserva blocos dinamicos (Hyper-V/WSL/Docker) onde o bind falha com
  // WSAEACCES (10013). A faixa antiga (40000..60000) atravessava essas reservas
  // e falhava de forma intermitente conforme a porta sorteada.
  Result := '127.0.0.1:' +
    IntToStr(20000 + (Int64(PipeTickMs) mod 18000) + PipeAtomicInc(GNameSeq));
end;

function TPipeTcpTransportTests.MissingAddress: string;
begin
  Result := '127.0.0.1:1'; // porta reservada, ninguem escuta
end;

function TPipeTcpTransportTests.TestTransport: TPipeTransport;
begin
  Result := ptTcp;
end;

procedure TPipeTransportTests.OpenLoopback;
var
  LName: string;
  LAcc: TAcceptThread;
begin
  LName := TestAddress;
  FListener := PipeCreateListener(LName, TestTransport);
  LAcc := TAcceptThread.Create(FListener, 1);
  try
    FClientEp := PipeConnect(LName, 3000, TestTransport);
    LAcc.WaitFor;
    FServerEp := LAcc.Accepted(0);
  finally
    LAcc.Free;
  end;
  Assert.IsNotNull(FServerEp, 'Accept nao devolveu endpoint');
end;

procedure TPipeTransportTests.DoConnectInexistente;
begin
  FClientEp := PipeConnect(MissingAddress, 300, TestTransport);
end;

procedure TPipeTransportTests.Loopback_EnviaERecebeNosDoisSentidos;
var
  LOut, LIn: TBytes;
  LLen: Integer;
begin
  OpenLoopback;

  // cliente -> servidor
  LOut := PipeUtf8Encode('ping');
  FClientEp.WriteExactly(LOut[0], Length(LOut));
  SetLength(LIn, 16);
  LLen := FServerEp.Read(LIn[0], 16);
  EqualInt(4, LLen);
  SetLength(LIn, LLen);
  Assert.AreEqual('ping', PipeUtf8Decode(LIn));

  // servidor -> cliente
  LOut := PipeUtf8Encode('pong!');
  FServerEp.WriteExactly(LOut[0], Length(LOut));
  SetLength(LIn, 16);
  LLen := FClientEp.Read(LIn[0], 16);
  EqualInt(5, LLen);
  SetLength(LIn, LLen);
  Assert.AreEqual('pong!', PipeUtf8Decode(LIn));
end;

procedure TPipeTransportTests.Loopback_FrameNpf1FimAFim;
var
  LCliStream, LSrvStream: TPipeEndpointStream;
  LFrame: TPipeFrame;
begin
  OpenLoopback;
  LCliStream := TPipeEndpointStream.Create(FClientEp);
  LSrvStream := TPipeEndpointStream.Create(FServerEp);
  try
    PipeWriteFrame(LCliStream, TPipeFrame.Request(99, PipeUtf8Encode('soma 2+2')),
      PIPES_DEFAULT_MAX_MESSAGE_SIZE);
    LFrame := PipeReadFrame(LSrvStream, PIPES_DEFAULT_MAX_MESSAGE_SIZE);
    Assert.IsTrue(LFrame.Kind = pfkRequest, 'kind devia ser request');
    Assert.IsTrue(LFrame.CorrId = 99, 'corrId nao preservado');
    Assert.AreEqual('soma 2+2', LFrame.PayloadAsText);

    PipeWriteFrame(LSrvStream, TPipeFrame.Reply(99, PipeUtf8Encode('4')),
      PIPES_DEFAULT_MAX_MESSAGE_SIZE);
    LFrame := PipeReadFrame(LCliStream, PIPES_DEFAULT_MAX_MESSAGE_SIZE);
    Assert.IsTrue(LFrame.Kind = pfkReply, 'kind devia ser reply');
    Assert.IsTrue(LFrame.CorrId = 99, 'corrId do reply nao preservado');
    Assert.AreEqual('4', LFrame.PayloadAsText);
  finally
    LCliStream.Free;
    LSrvStream.Free;
  end;
end;

procedure TPipeTransportTests.Accept_DesbloqueiaComClose;
var
  LAcc: TAcceptThread;
  T0: UInt64;
begin
  FListener := PipeCreateListener(UniquePipeName);
  LAcc := TAcceptThread.Create(FListener, 1);
  try
    Sleep(100); // deixa a thread entrar no Accept
    T0 := PipeTickMs;
    FListener.Close;
    LAcc.WaitFor;
    Assert.IsTrue(PipeTickMs - T0 < 2000, 'Close nao desbloqueou o Accept em ate 2s');
    Assert.IsNull(LAcc.Accepted(0), 'Accept devia devolver nil apos Close');
  finally
    LAcc.Free;
  end;
end;

procedure TPipeTransportTests.Read_DesbloqueiaComCloseAbort;
var
  LReader: TReadOneThread;
  T0: UInt64;
begin
  OpenLoopback;
  LReader := TReadOneThread.Create(FServerEp);
  try
    Sleep(100); // deixa a thread entrar no Read
    T0 := PipeTickMs;
    FServerEp.CloseAbort;
    LReader.WaitFor;
    Assert.IsTrue(PipeTickMs - T0 < 2000, 'CloseAbort nao desbloqueou o Read em ate 2s');
    Assert.IsTrue(LReader.GotClosed, 'Read abortado devia levantar EPipeClosed');
  finally
    LReader.Free;
  end;
end;

procedure TPipeTransportTests.Read_DetectaQuedaDoPar;
var
  LReader: TReadOneThread;
  T0: UInt64;
begin
  OpenLoopback;
  LReader := TReadOneThread.Create(FServerEp);
  try
    Sleep(100);
    T0 := PipeTickMs;
    FClientEp.CloseAbort;
    FreeAndNil(FClientEp); // fecha o handle do cliente: par do servidor caiu
    LReader.WaitFor;
    Assert.IsTrue(PipeTickMs - T0 < 2000, 'queda do par nao desbloqueou o Read em ate 2s');
    Assert.IsTrue(LReader.GotClosed, 'queda do par devia levantar EPipeClosed');
  finally
    LReader.Free;
  end;
end;

procedure TPipeTransportTests.Connect_TimeoutQuandoServidorNaoExiste;
var
  T0: UInt64;
begin
  T0 := PipeTickMs;
  Assert.WillRaise(DoConnectInexistente, EPipeTimeout);
  Assert.IsTrue(PipeTickMs - T0 >= 250, 'timeout retornou cedo demais');
  Assert.IsTrue(PipeTickMs - T0 < 5000, 'timeout demorou demais');
end;

procedure TPipeTransportTests.MultiplosClientes_CadaUmComSeuEndpoint;
var
  LName: string;
  LAcc: TAcceptThread;
  LClients: array[0..2] of TPipeEndpoint;
  LByte: Byte;
  LSum, I, LLen: Integer;
begin
  LName := UniquePipeName;
  FListener := PipeCreateListener(LName);
  LClients[0] := nil; LClients[1] := nil; LClients[2] := nil;
  LAcc := TAcceptThread.Create(FListener, 3);
  try
    for I := 0 to 2 do
      LClients[I] := PipeConnect(LName, 3000);
    LAcc.WaitFor;
    for I := 0 to 2 do
      Assert.IsNotNull(LAcc.Accepted(I), 'endpoint do servidor ' + IntToStr(I) + ' nulo');

    // Cada cliente manda um byte proprio; o conjunto {1,2,3} deve chegar
    // (sem assumir a ordem de accept).
    for I := 0 to 2 do
    begin
      LByte := I + 1;
      LClients[I].WriteExactly(LByte, 1);
    end;
    LSum := 0;
    for I := 0 to 2 do
    begin
      LLen := LAcc.Accepted(I).Read(LByte, 1);
      EqualInt(1, LLen);
      Assert.IsTrue((LByte >= 1) and (LByte <= 3), 'byte fora do esperado');
      LSum := LSum + LByte;
    end;
    EqualInt(6, LSum); // 1+2+3: os tres clientes chegaram, sem duplicata
  finally
    for I := 0 to 2 do
      LClients[I].Free;
    for I := 0 to 2 do
      LAcc.Accepted(I).Free;
    LAcc.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TPipeTransportTests);
  TDUnitX.RegisterTestFixture(TPipeTcpTransportTests);

end.
