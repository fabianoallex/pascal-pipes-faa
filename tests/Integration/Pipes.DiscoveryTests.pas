unit Pipes.DiscoveryTests;

{ Testes de integracao da descoberta (TPipeDiscoveryResponder +
  PipeDiscoverServers) via loopback, sempre com a forma DIRIGIDA
  ('127.0.0.1'): broadcast de verdade depende de interface/firewall e nao e'
  deterministico em maquina de CI — o que a forma dirigida nao cobre e' so' o
  sendto para 255.255.255.255, mesmo socket e mesma coleta. Mestre DUnitX; o
  espelho FPCUnit em tests/Integration/fpc e' gerado por
  tools/gen_fpc_mirror.py.

  As portas sao fixas (faixa 457xx): colisao com servico real da maquina e'
  improvavel e apareceria como EPipeError de bind, nao como falha silenciosa. }

interface

uses
  DUnitX.TestFramework,
  Pipes.DUnitXCompat,
  SysUtils,
  Pipes.Types,
  PascalCommon.Threading,
  Pipes.Discovery;

type
  [TestFixture]
  TPipeDiscoveryIntegrationTests = class
  private
    FRespA: TPipeDiscoveryResponder;
    FRespB: TPipeDiscoveryResponder;
    // Alvo do AssertException (campos + metodo, nunca closure).
    procedure DoStartRespB;
  public
    [Setup] procedure SetUp;
    [TearDown] procedure TearDown;
  public
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
  TAssert.AssertTrue('Active apos Start', FRespA.Active);
  // Janela de 700ms > cadencia de reenvio (300ms): o responder respondera a
  // 2-3 sondas e o dedup tem que reduzir a UMA entrada.
  LFound := PipeDiscoverServers('127.0.0.1', 700, PORTA_DESC_A, 'tok-teste');
  TAssert.AssertEquals('exatamente um servidor (dedup de reenvio)', 1, Length(LFound));
  TAssert.AssertEquals('Address = IP do envelope + porta anunciada',
    '127.0.0.1:' + IntToStr(PORTA_SERVICO_A), LFound[0].Address);
  TAssert.AssertTrue('transporte preservado', LFound[0].Transport = ptTls);
  TAssert.AssertEquals('nome preservado', 'Retaguarda Teste', LFound[0].Name);
end;

procedure TPipeDiscoveryIntegrationTests.TokenErrado_ListaVazia;
var
  LFound: TArray<TPipeServerInfo>;
begin
  FRespA := TPipeDiscoveryResponder.Create(PORTA_SERVICO_A, ptTcp, 'A',
    PORTA_DESC_A, 'tok-a');
  FRespA.Start;
  LFound := PipeDiscoverServers('127.0.0.1', 300, PORTA_DESC_A, 'tok-b');
  TAssert.AssertEquals('outra instalacao nao aparece', 0, Length(LFound));
end;

procedure TPipeDiscoveryIntegrationTests.SemResponder_ListaVazia;
var
  LFound: TArray<TPipeServerInfo>;
begin
  // Sonda para porta fechada: o SO devolve ICMP "porta inalcancavel", que o
  // canal tem que engolir (ECONNREFUSED/WSAECONNRESET) sem abortar a coleta.
  LFound := PipeDiscoverServers('127.0.0.1', 300, PORTA_DESC_B, '');
  TAssert.AssertEquals('ninguem respondeu = lista vazia, nao erro', 0, Length(LFound));
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
  TAssert.AssertEquals('porta A acha um', 1, Length(LFound));
  TAssert.AssertEquals('porta A acha o A', 'A', LFound[0].Name);
  LFound := PipeDiscoverServers('127.0.0.1', 300, PORTA_DESC_B, '');
  TAssert.AssertEquals('porta B acha um', 1, Length(LFound));
  TAssert.AssertEquals('porta B acha o B', 'B', LFound[0].Name);
end;

procedure TPipeDiscoveryIntegrationTests.PortaOcupada_StartLevanta;
begin
  FRespA := TPipeDiscoveryResponder.Create(PORTA_SERVICO_A, ptTcp, 'A',
    PORTA_DESC_A, '');
  FRespA.Start;
  FRespB := TPipeDiscoveryResponder.Create(PORTA_SERVICO_B, ptTcp, 'B',
    PORTA_DESC_A, ''); // mesma porta de descoberta, de proposito
  TAssert.AssertException('um responder por porta', EPipeError, DoStartRespB);
  TAssert.AssertFalse('o segundo nao ficou ativo', FRespB.Active);
  TAssert.AssertTrue('o primeiro segue ativo', FRespA.Active);
end;

procedure TPipeDiscoveryIntegrationTests.StopRapido_EReutilizavel;
var
  LFound: TArray<TPipeServerInfo>;
  LInicio: UInt64;
begin
  FRespA := TPipeDiscoveryResponder.Create(PORTA_SERVICO_A, ptTcp, 'A',
    PORTA_DESC_A, '');
  FRespA.Start;
  LInicio := PcTickMs;
  FRespA.Stop;
  TAssert.AssertTrue('Stop com thread ociosa conclui em < 2s (levou ' +
    IntToStr(Int64(PcTickMs - LInicio)) + 'ms)',
    PcTickMs - LInicio < 2000);
  TAssert.AssertFalse('inativo apos Stop', FRespA.Active);
  LFound := PipeDiscoverServers('127.0.0.1', 300, PORTA_DESC_A, '');
  TAssert.AssertEquals('parado nao responde', 0, Length(LFound));
  // A porta tem que ter sido liberada: Start de novo no MESMO objeto.
  FRespA.Start;
  LFound := PipeDiscoverServers('127.0.0.1', 700, PORTA_DESC_A, '');
  TAssert.AssertEquals('reutilizavel apos Stop', 1, Length(LFound));
end;

initialization
  TDUnitX.RegisterTestFixture(TPipeDiscoveryIntegrationTests);

end.
