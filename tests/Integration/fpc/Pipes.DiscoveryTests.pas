unit Pipes.DiscoveryTests;

{$mode delphi}{$H+}

{ Testes de integracao da descoberta (TPipeDiscoveryResponder +
  PipeDiscoverServers) via loopback, sempre com a forma DIRIGIDA
  ('127.0.0.1'): broadcast de verdade depende de interface/firewall e nao e'
  deterministico em maquina de CI — o que a forma dirigida nao cobre e' so' o
  sendto para 255.255.255.255, mesmo socket e mesma coleta. Versao FPCUnit;
  espelha a versao DUnitX em tests/Integration.

  As portas sao fixas (faixa 457xx): colisao com servico real da maquina e'
  improvavel e apareceria como EPipeError de bind, nao como falha silenciosa. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  Pipes.Types,
  Pipes.Threading,
  Pipes.Discovery;

type
  TPipeDiscoveryIntegrationTests = class(TTestCase)
  private
    FRespA: TPipeDiscoveryResponder;
    FRespB: TPipeDiscoveryResponder;
    // Alvo do AssertException (campos + metodo, nunca closure).
    procedure DoStartRespB;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure SondaDirigida_AchaResponder_SemDuplicatas;
    procedure TokenErrado_ListaVazia;
    procedure SemResponder_ListaVazia;
    procedure DoisResponders_CadaPortaAchaOSeu;
    procedure PortaOcupada_StartLevanta;
    procedure StopRapido_EReutilizavel;
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
  inherited;
  FRespA := nil;
  FRespB := nil;
end;

procedure TPipeDiscoveryIntegrationTests.TearDown;
begin
  FreeAndNil(FRespA); // Stop no destructor (idempotente)
  FreeAndNil(FRespB);
  inherited;
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
  AssertTrue('Active apos Start', FRespA.Active);
  // Janela de 700ms > cadencia de reenvio (300ms): o responder respondera a
  // 2-3 sondas e o dedup tem que reduzir a UMA entrada.
  LFound := PipeDiscoverServers('127.0.0.1', 700, PORTA_DESC_A, 'tok-teste');
  AssertEquals('exatamente um servidor (dedup de reenvio)', 1,
    Length(LFound));
  AssertEquals('Address = IP do envelope + porta anunciada',
    '127.0.0.1:' + IntToStr(PORTA_SERVICO_A), LFound[0].Address);
  AssertTrue('transporte preservado', LFound[0].Transport = ptTls);
  AssertEquals('nome preservado', 'Retaguarda Teste', LFound[0].Name);
end;

procedure TPipeDiscoveryIntegrationTests.TokenErrado_ListaVazia;
var
  LFound: TArray<TPipeServerInfo>;
begin
  FRespA := TPipeDiscoveryResponder.Create(PORTA_SERVICO_A, ptTcp, 'A',
    PORTA_DESC_A, 'tok-a');
  FRespA.Start;
  LFound := PipeDiscoverServers('127.0.0.1', 300, PORTA_DESC_A, 'tok-b');
  AssertEquals('outra instalacao nao aparece', 0, Length(LFound));
end;

procedure TPipeDiscoveryIntegrationTests.SemResponder_ListaVazia;
var
  LFound: TArray<TPipeServerInfo>;
begin
  // Sonda para porta fechada: o SO devolve ICMP "porta inalcancavel", que o
  // canal tem que engolir (ECONNREFUSED/WSAECONNRESET) sem abortar a coleta.
  LFound := PipeDiscoverServers('127.0.0.1', 300, PORTA_DESC_B, '');
  AssertEquals('ninguem respondeu = lista vazia, nao erro', 0,
    Length(LFound));
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
  AssertEquals('porta A acha um', 1, Length(LFound));
  AssertEquals('porta A acha o A', 'A', LFound[0].Name);
  LFound := PipeDiscoverServers('127.0.0.1', 300, PORTA_DESC_B, '');
  AssertEquals('porta B acha um', 1, Length(LFound));
  AssertEquals('porta B acha o B', 'B', LFound[0].Name);
end;

procedure TPipeDiscoveryIntegrationTests.PortaOcupada_StartLevanta;
begin
  FRespA := TPipeDiscoveryResponder.Create(PORTA_SERVICO_A, ptTcp, 'A',
    PORTA_DESC_A, '');
  FRespA.Start;
  FRespB := TPipeDiscoveryResponder.Create(PORTA_SERVICO_B, ptTcp, 'B',
    PORTA_DESC_A, ''); // mesma porta de descoberta, de proposito
  AssertException('um responder por porta', EPipeError, DoStartRespB);
  AssertFalse('o segundo nao ficou ativo', FRespB.Active);
  AssertTrue('o primeiro segue ativo', FRespA.Active);
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
  AssertTrue('Stop com thread ociosa conclui em < 2s (levou ' +
    IntToStr(Int64(PipeTickMs - LInicio)) + 'ms)',
    PipeTickMs - LInicio < 2000);
  AssertFalse('inativo apos Stop', FRespA.Active);
  LFound := PipeDiscoverServers('127.0.0.1', 300, PORTA_DESC_A, '');
  AssertEquals('parado nao responde', 0, Length(LFound));
  // A porta tem que ter sido liberada: Start de novo no MESMO objeto.
  FRespA.Start;
  LFound := PipeDiscoverServers('127.0.0.1', 700, PORTA_DESC_A, '');
  AssertEquals('reutilizavel apos Stop', 1, Length(LFound));
end;

initialization
  RegisterTest(TPipeDiscoveryIntegrationTests);

end.
