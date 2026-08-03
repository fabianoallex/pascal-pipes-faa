unit Pipes.DiscoveryTests;

{ Testes de integracao da descoberta (TPipeDiscoveryResponder +
  PipeDiscoverServers) via loopback, sempre com a forma DIRIGIDA
  ('127.0.0.1'): broadcast de verdade depende de interface/firewall e nao e'
  deterministico em maquina de CI — o que a forma dirigida nao cobre e' so' o
  sendto para 255.255.255.255, mesmo socket e mesma coleta. Versao
  DUnitX/Delphi; a versao FPCUnit em tests/Integration/fpc espelha a mesma
  cobertura.

  As portas sao fixas (faixa 457xx): colisao com servico real da maquina e'
  improvavel e apareceria como EPipeError de bind, nao como falha silenciosa. }

interface

uses
  DUnitX.TestFramework,
  SysUtils,
  Pipes.Types,
  Pipes.Threading,
  Pipes.Discovery;

type
  [TestFixture]
  TPipeDiscoveryIntegrationTests = class
  private
    FRespA: TPipeDiscoveryResponder;
    FRespB: TPipeDiscoveryResponder;
    // Alvo do WillRaise (campos + metodo, nunca closure).
    procedure DoStartRespB;
  public
    [Setup] procedure SetUp;
    [TearDown] procedure TearDown;
  published
    [Test] procedure SondaDirigida_AchaResponder_SemDuplicatas;
    [Test] procedure TokenErrado_ListaVazia;
    [Test] procedure SemResponder_ListaVazia;
    [Test] procedure DoisResponders_CadaPortaAchaOSeu;
    [Test] procedure PortaOcupada_StartLevanta;
    [Test] procedure StopRapido_EReutilizavel;
  end;

implementation

const
  PORTA_DESC_A  = 45710; // porta de descoberta do responder A
  PORTA_DESC_B  = 45711; // porta de descoberta do responder B
  PORTA_SERVICO_A = 47001; // porta ANUNCIADA (nada escuta nela; descoberta
  PORTA_SERVICO_B = 47002; // so' reporta — conectar e' problema do cliente)

// Compara como Integer (E2532, mesma razao do EqualInt em outros testes).
procedure EqualInt(AExpected, AActual: Integer; const AMsg: string);
begin
  Assert.AreEqual(AExpected, AActual, AMsg);
end;

{ TPipeDiscoveryIntegrationTests }

procedure TPipeDiscoveryIntegrationTests.SetUp;
begin
  FRespA := nil;
  FRespB := nil;
end;

procedure TPipeDiscoveryIntegrationTests.TearDown;
begin
  FreeAndNil(FRespA); // Stop no destructor (idempotente)
  FreeAndNil(FRespB);
end;

procedure TPipeDiscoveryIntegrationTests.DoStartRespB;
begin
  FRespB.Start;
end;

procedure TPipeDiscoveryIntegrationTests.SondaDirigida_AchaResponder_SemDuplicatas;
var
  LFound: TArray<TPipeServerInfo>;
begin
  FRespA := TPipeDiscoveryResponder.Create(PORTA_SERVICO_A, ptTls,
    'Retaguarda Teste', PORTA_DESC_A, 'tok-teste');
  FRespA.Start;
  Assert.IsTrue(FRespA.Active, 'Active apos Start');
  // Janela de 700ms > cadencia de reenvio (300ms): o responder respondera a
  // 2-3 sondas e o dedup tem que reduzir a UMA entrada.
  LFound := PipeDiscoverServers('127.0.0.1', 700, PORTA_DESC_A, 'tok-teste');
  EqualInt(1, Length(LFound), 'exatamente um servidor (dedup de reenvio)');
  Assert.AreEqual('127.0.0.1:' + IntToStr(PORTA_SERVICO_A),
    LFound[0].Address, 'Address = IP do envelope + porta anunciada');
  Assert.IsTrue(LFound[0].Transport = ptTls, 'transporte preservado');
  Assert.AreEqual('Retaguarda Teste', LFound[0].Name, 'nome preservado');
end;

procedure TPipeDiscoveryIntegrationTests.TokenErrado_ListaVazia;
var
  LFound: TArray<TPipeServerInfo>;
begin
  FRespA := TPipeDiscoveryResponder.Create(PORTA_SERVICO_A, ptTcp, 'A',
    PORTA_DESC_A, 'tok-a');
  FRespA.Start;
  LFound := PipeDiscoverServers('127.0.0.1', 300, PORTA_DESC_A, 'tok-b');
  EqualInt(0, Length(LFound), 'outra instalacao nao aparece');
end;

procedure TPipeDiscoveryIntegrationTests.SemResponder_ListaVazia;
var
  LFound: TArray<TPipeServerInfo>;
begin
  // Sonda para porta fechada: o SO devolve ICMP "porta inalcancavel", que o
  // canal tem que engolir (ECONNREFUSED/WSAECONNRESET) sem abortar a coleta.
  LFound := PipeDiscoverServers('127.0.0.1', 300, PORTA_DESC_B, '');
  EqualInt(0, Length(LFound), 'ninguem respondeu = lista vazia, nao erro');
end;

procedure TPipeDiscoveryIntegrationTests.DoisResponders_CadaPortaAchaOSeu;
var
  LFound: TArray<TPipeServerInfo>;
begin
  FRespA := TPipeDiscoveryResponder.Create(PORTA_SERVICO_A, ptTcp, 'A',
    PORTA_DESC_A, '');
  FRespB := TPipeDiscoveryResponder.Create(PORTA_SERVICO_B, ptTcp, 'B',
    PORTA_DESC_B, '');
  FRespA.Start;
  FRespB.Start;
  LFound := PipeDiscoverServers('127.0.0.1', 300, PORTA_DESC_A, '');
  EqualInt(1, Length(LFound), 'porta A acha um');
  Assert.AreEqual('A', LFound[0].Name, 'porta A acha o A');
  LFound := PipeDiscoverServers('127.0.0.1', 300, PORTA_DESC_B, '');
  EqualInt(1, Length(LFound), 'porta B acha um');
  Assert.AreEqual('B', LFound[0].Name, 'porta B acha o B');
end;

procedure TPipeDiscoveryIntegrationTests.PortaOcupada_StartLevanta;
begin
  FRespA := TPipeDiscoveryResponder.Create(PORTA_SERVICO_A, ptTcp, 'A',
    PORTA_DESC_A, '');
  FRespA.Start;
  FRespB := TPipeDiscoveryResponder.Create(PORTA_SERVICO_B, ptTcp, 'B',
    PORTA_DESC_A, ''); // mesma porta de descoberta, de proposito
  Assert.WillRaise(DoStartRespB, EPipeError, 'um responder por porta');
  Assert.IsFalse(FRespB.Active, 'o segundo nao ficou ativo');
  Assert.IsTrue(FRespA.Active, 'o primeiro segue ativo');
end;

procedure TPipeDiscoveryIntegrationTests.StopRapido_EReutilizavel;
var
  LFound: TArray<TPipeServerInfo>;
  LInicio: UInt64;
begin
  FRespA := TPipeDiscoveryResponder.Create(PORTA_SERVICO_A, ptTcp, 'A',
    PORTA_DESC_A, '');
  FRespA.Start;
  LInicio := PipeTickMs;
  FRespA.Stop;
  Assert.IsTrue(PipeTickMs - LInicio < 2000,
    'Stop com thread ociosa conclui em < 2s (levou ' +
    IntToStr(Int64(PipeTickMs - LInicio)) + 'ms)');
  Assert.IsFalse(FRespA.Active, 'inativo apos Stop');
  LFound := PipeDiscoverServers('127.0.0.1', 300, PORTA_DESC_A, '');
  EqualInt(0, Length(LFound), 'parado nao responde');
  // A porta tem que ter sido liberada: Start de novo no MESMO objeto.
  FRespA.Start;
  LFound := PipeDiscoverServers('127.0.0.1', 700, PORTA_DESC_A, '');
  EqualInt(1, Length(LFound), 'reutilizavel apos Stop');
end;

initialization
  TDUnitX.RegisterTestFixture(TPipeDiscoveryIntegrationTests);

end.
