unit Pipes.DiscoveryTests;

{ Testes do protocolo NPD1 e dos helpers IPv4 de Pipes.Discovery — so' as
  funcoes puras (encode/decode), sem socket nenhum; o caminho com rede fica no
  teste de integracao. Versao DUnitX/Delphi; a versao FPCUnit em
  tests/Unit/fpc espelha a mesma cobertura. }

interface

uses
  DUnitX.TestFramework,
  SysUtils,
  Pipes.Types,
  Pipes.Discovery;

type
  [TestFixture]
  TPipeDiscoveryTests = class
  private
    FToken: string;
    FName: string;
    FPort: Word;
    // Alvos dos WillRaise/AssertException: campos + metodo, nunca closure
    // (mesmo padrao do Pipes.AddressTests, que mantem o espelho FPC 1:1).
    procedure DoEncodeProbe;
    procedure DoEncodeResponse;
    /// Copia ADatagram com o byte AIndex substituido por AValue.
    function Corrupt(const ADatagram: TBytes; AIndex: Integer;
      AValue: Byte): TBytes;
    /// Copia ADatagram com ADelta bytes a mais (zerados) ou a menos.
    function Resize(const ADatagram: TBytes; ADelta: Integer): TBytes;
  published
    [Test] procedure Probe_RoundTrip_SemToken;
    [Test] procedure Probe_RoundTrip_ComToken;
    [Test] procedure Probe_TokenErrado_Recusa;
    [Test] procedure Probe_MagicErrado_Recusa;
    [Test] procedure Probe_KindDeResposta_Recusa;
    [Test] procedure Probe_ComSobra_Recusa;
    [Test] procedure Probe_Truncada_Recusa;
    [Test] procedure Probe_TokenLongoDemais_Levanta;
    [Test] procedure Response_RoundTrip;
    [Test] procedure Response_RoundTrip_NomeVazioETokenVazio;
    [Test] procedure Response_RoundTrip_NomeUtf8;
    [Test] procedure Response_NomeNoLimite_RoundTrip;
    [Test] procedure Response_TransporteDesconhecido_Recusa;
    [Test] procedure Response_ComSobra_Recusa;
    [Test] procedure Response_Truncada_Recusa;
    [Test] procedure Response_TokenErrado_Recusa;
    [Test] procedure Response_PortaZero_Recusa;
    [Test] procedure Encode_PortaZero_Levanta;
    [Test] procedure Encode_NomeLongoDemais_Levanta;
    [Test] procedure Ipv4_RoundTrip;
    [Test] procedure Ipv4_OrdemDeRede;
    [Test] procedure Ipv4_LiteraisInvalidos_Recusa;
  end;

implementation

// Compara como Integer: Word/Byte vs Integer nao infere T em AreEqual<T>
// (E2532), mesma razao do EqualInt em Pipes.FramingTests.
procedure EqualInt(AExpected, AActual: Integer; const AMsg: string);
begin
  Assert.AreEqual(AExpected, AActual, AMsg);
end;

{ TPipeDiscoveryTests }

procedure TPipeDiscoveryTests.DoEncodeProbe;
begin
  PipeDiscoveryEncodeProbe(FToken);
end;

procedure TPipeDiscoveryTests.DoEncodeResponse;
begin
  PipeDiscoveryEncodeResponse(FPort, ptTcp, FName, FToken);
end;

function TPipeDiscoveryTests.Corrupt(const ADatagram: TBytes; AIndex: Integer;
  AValue: Byte): TBytes;
begin
  Result := Copy(ADatagram, 0, Length(ADatagram));
  Result[AIndex] := AValue;
end;

function TPipeDiscoveryTests.Resize(const ADatagram: TBytes;
  ADelta: Integer): TBytes;
begin
  Result := Copy(ADatagram, 0, Length(ADatagram));
  SetLength(Result, Length(Result) + ADelta);
end;

procedure TPipeDiscoveryTests.Probe_RoundTrip_SemToken;
var
  LProbe: TBytes;
begin
  LProbe := PipeDiscoveryEncodeProbe('');
  EqualInt(6, Length(LProbe), 'sonda sem token = so o header');
  Assert.IsTrue(PipeDiscoveryTryDecodeProbe(LProbe, ''),
    'sonda valida deveria decodificar');
end;

procedure TPipeDiscoveryTests.Probe_RoundTrip_ComToken;
var
  LProbe: TBytes;
begin
  LProbe := PipeDiscoveryEncodeProbe('loja-03');
  Assert.IsTrue(PipeDiscoveryTryDecodeProbe(LProbe, 'loja-03'),
    'token igual deveria casar');
end;

procedure TPipeDiscoveryTests.Probe_TokenErrado_Recusa;
var
  LProbe: TBytes;
begin
  LProbe := PipeDiscoveryEncodeProbe('loja-03');
  Assert.IsFalse(PipeDiscoveryTryDecodeProbe(LProbe, 'loja-04'),
    'token diferente nao pode casar');
  Assert.IsFalse(PipeDiscoveryTryDecodeProbe(LProbe, ''),
    'token vazio nao casa com sonda com token');
  Assert.IsFalse(
    PipeDiscoveryTryDecodeProbe(PipeDiscoveryEncodeProbe(''), 'loja-03'),
    'sonda sem token nao casa com token esperado');
end;

procedure TPipeDiscoveryTests.Probe_MagicErrado_Recusa;
var
  LProbe: TBytes;
begin
  LProbe := PipeDiscoveryEncodeProbe('');
  Assert.IsFalse(PipeDiscoveryTryDecodeProbe(Corrupt(LProbe, 0, Ord('X')), ''),
    'magic corrompido nao pode decodificar');
end;

procedure TPipeDiscoveryTests.Probe_KindDeResposta_Recusa;
var
  LResponse: TBytes;
begin
  // Uma RESPOSTA nunca pode ser aceita como sonda (senao dois responders na
  // mesma porta entrariam em loop respondendo um ao outro).
  LResponse := PipeDiscoveryEncodeResponse(5000, ptTcp, '', '');
  Assert.IsFalse(PipeDiscoveryTryDecodeProbe(LResponse, ''),
    'resposta nao e sonda');
end;

procedure TPipeDiscoveryTests.Probe_ComSobra_Recusa;
var
  LProbe: TBytes;
begin
  LProbe := PipeDiscoveryEncodeProbe('tok');
  Assert.IsFalse(PipeDiscoveryTryDecodeProbe(Resize(LProbe, 1), 'tok'),
    'comprimento e estrito: sobra = lixo');
end;

procedure TPipeDiscoveryTests.Probe_Truncada_Recusa;
var
  LProbe: TBytes;
begin
  LProbe := PipeDiscoveryEncodeProbe('tok');
  Assert.IsFalse(PipeDiscoveryTryDecodeProbe(Resize(LProbe, -1), 'tok'),
    'truncada nao decodifica');
  Assert.IsFalse(PipeDiscoveryTryDecodeProbe(Resize(LProbe, -Length(LProbe)),
    'tok'), 'datagrama vazio nao decodifica');
end;

procedure TPipeDiscoveryTests.Probe_TokenLongoDemais_Levanta;
begin
  FToken := StringOfChar('x', PIPES_DISCOVERY_MAX_TOKEN_BYTES + 1);
  Assert.WillRaise(DoEncodeProbe, EPipeError, 'token acima do teto');
end;

procedure TPipeDiscoveryTests.Response_RoundTrip;
var
  LResp: TBytes;
  LPort: Word;
  LTransport: TPipeTransport;
  LName: string;
begin
  LResp := PipeDiscoveryEncodeResponse(5000, ptTls, 'Retaguarda Loja 3',
    'loja-03');
  Assert.IsTrue(PipeDiscoveryTryDecodeResponse(LResp, 'loja-03', LPort,
    LTransport, LName), 'resposta valida deveria decodificar');
  EqualInt(5000, LPort, 'porta preservada');
  Assert.IsTrue(LTransport = ptTls, 'transporte preservado');
  Assert.AreEqual('Retaguarda Loja 3', LName, 'nome preservado');
end;

procedure TPipeDiscoveryTests.Response_RoundTrip_NomeVazioETokenVazio;
var
  LResp: TBytes;
  LPort: Word;
  LTransport: TPipeTransport;
  LName: string;
begin
  LResp := PipeDiscoveryEncodeResponse(65535, ptLocal, '', '');
  Assert.IsTrue(PipeDiscoveryTryDecodeResponse(LResp, '', LPort, LTransport,
    LName), 'nome e token vazios sao validos');
  EqualInt(65535, LPort, 'porta maxima preservada');
  Assert.IsTrue(LTransport = ptLocal, 'transporte preservado');
  Assert.AreEqual('', LName, 'nome vazio preservado');
end;

procedure TPipeDiscoveryTests.Response_RoundTrip_NomeUtf8;
var
  LResp: TBytes;
  LPort: Word;
  LTransport: TPipeTransport;
  LName: string;
const
  // Multibyte de proposito (2 bytes por acento em UTF-8): o comprimento no
  // fio e' em BYTES, nao em chars.
  NOME_ACENTUADO = 'Padaria S' + #$00E3 + 'o Jo' + #$00E3 + 'o';
begin
  LResp := PipeDiscoveryEncodeResponse(1, ptTcp, NOME_ACENTUADO, '');
  Assert.IsTrue(PipeDiscoveryTryDecodeResponse(LResp, '', LPort, LTransport,
    LName), 'nome UTF-8 deveria decodificar');
  Assert.AreEqual(NOME_ACENTUADO, LName, 'nome multibyte preservado');
end;

procedure TPipeDiscoveryTests.Response_NomeNoLimite_RoundTrip;
var
  LResp: TBytes;
  LPort: Word;
  LTransport: TPipeTransport;
  LName: string;
begin
  LResp := PipeDiscoveryEncodeResponse(80, ptTcp,
    StringOfChar('n', PIPES_DISCOVERY_MAX_NAME_BYTES), '');
  Assert.IsTrue(PipeDiscoveryTryDecodeResponse(LResp, '', LPort, LTransport,
    LName), 'nome exatamente no teto e valido');
  EqualInt(PIPES_DISCOVERY_MAX_NAME_BYTES, Length(LName),
    'nome no limite preservado');
end;

procedure TPipeDiscoveryTests.Response_TransporteDesconhecido_Recusa;
var
  LResp: TBytes;
  LPort: Word;
  LTransport: TPipeTransport;
  LName: string;
begin
  LResp := PipeDiscoveryEncodeResponse(5000, ptTcp, '', '');
  // O byte de transporte vem logo apos a porta (header 6 + porta 2 = indice 8
  // com token vazio).
  Assert.IsFalse(PipeDiscoveryTryDecodeResponse(Corrupt(LResp, 8, 250), '',
    LPort, LTransport, LName),
    'transporte de versao futura: recusa, nao adivinha');
end;

procedure TPipeDiscoveryTests.Response_ComSobra_Recusa;
var
  LResp: TBytes;
  LPort: Word;
  LTransport: TPipeTransport;
  LName: string;
begin
  LResp := PipeDiscoveryEncodeResponse(5000, ptTcp, 'srv', '');
  Assert.IsFalse(PipeDiscoveryTryDecodeResponse(Resize(LResp, 3), '', LPort,
    LTransport, LName), 'comprimento e estrito: sobra = lixo');
end;

procedure TPipeDiscoveryTests.Response_Truncada_Recusa;
var
  LResp: TBytes;
  LPort: Word;
  LTransport: TPipeTransport;
  LName: string;
begin
  LResp := PipeDiscoveryEncodeResponse(5000, ptTcp, 'srv', '');
  Assert.IsFalse(PipeDiscoveryTryDecodeResponse(Resize(LResp, -1), '', LPort,
    LTransport, LName), 'nome anunciado maior que o datagrama');
  Assert.IsFalse(PipeDiscoveryTryDecodeResponse(Resize(LResp, -4), '', LPort,
    LTransport, LName), 'corpo truncado');
end;

procedure TPipeDiscoveryTests.Response_TokenErrado_Recusa;
var
  LResp: TBytes;
  LPort: Word;
  LTransport: TPipeTransport;
  LName: string;
begin
  LResp := PipeDiscoveryEncodeResponse(5000, ptTcp, '', 'loja-03');
  Assert.IsFalse(PipeDiscoveryTryDecodeResponse(LResp, 'loja-04', LPort,
    LTransport, LName), 'resposta de outra instalacao nao entra na lista');
end;

procedure TPipeDiscoveryTests.Response_PortaZero_Recusa;
var
  LResp: TBytes;
  LPort: Word;
  LTransport: TPipeTransport;
  LName: string;
begin
  // O encode recusa porta 0, entao o datagrama malicioso e' montado a mao:
  // porta fica nos indices 6..7 com token vazio.
  LResp := PipeDiscoveryEncodeResponse(5000, ptTcp, '', '');
  LResp := Corrupt(LResp, 6, 0);
  LResp := Corrupt(LResp, 7, 0);
  Assert.IsFalse(PipeDiscoveryTryDecodeResponse(LResp, '', LPort, LTransport,
    LName), 'porta 0 no fio e recusada');
end;

procedure TPipeDiscoveryTests.Encode_PortaZero_Levanta;
begin
  FPort := 0;
  FName := '';
  FToken := '';
  Assert.WillRaise(DoEncodeResponse, EPipeError, 'porta 0 nao e anunciavel');
end;

procedure TPipeDiscoveryTests.Encode_NomeLongoDemais_Levanta;
begin
  FPort := 5000;
  FName := StringOfChar('n', PIPES_DISCOVERY_MAX_NAME_BYTES + 1);
  FToken := '';
  Assert.WillRaise(DoEncodeResponse, EPipeError, 'nome acima do teto');
end;

procedure TPipeDiscoveryTests.Ipv4_RoundTrip;
var
  LAddr: LongWord;
begin
  Assert.IsTrue(PipeTryStringToIPv4('192.168.1.10', LAddr), '192.168.1.10');
  Assert.AreEqual('192.168.1.10', PipeIPv4ToString(LAddr), 'roundtrip');
  Assert.IsTrue(PipeTryStringToIPv4('0.0.0.0', LAddr), '0.0.0.0');
  Assert.AreEqual('0.0.0.0', PipeIPv4ToString(LAddr), 'roundtrip zeros');
  Assert.IsTrue(PipeTryStringToIPv4('255.255.255.255', LAddr), 'broadcast');
  Assert.AreEqual('255.255.255.255', PipeIPv4ToString(LAddr),
    'roundtrip broadcast');
end;

procedure TPipeDiscoveryTests.Ipv4_OrdemDeRede;
var
  LAddr: LongWord;
begin
  // Em ordem de rede num host little-endian, 1.2.3.4 = $04030201 (primeiro
  // octeto no byte mais baixo) — e' o layout que sin_addr espera.
  Assert.IsTrue(PipeTryStringToIPv4('1.2.3.4', LAddr), '1.2.3.4');
  // Comparado via IsTrue: AreEqual com LongWord nao infere T (E2532, mesma
  // razao do EqualInt acima).
  Assert.IsTrue(LAddr = LongWord($04030201), 'layout de sin_addr');
  Assert.AreEqual('1.2.3.4', PipeIPv4ToString(LongWord($04030201)),
    'volta do mesmo valor');
end;

procedure TPipeDiscoveryTests.Ipv4_LiteraisInvalidos_Recusa;
var
  LAddr: LongWord;
begin
  Assert.IsFalse(PipeTryStringToIPv4('', LAddr), 'vazio');
  Assert.IsFalse(PipeTryStringToIPv4('servidor01', LAddr), 'nome de host');
  Assert.IsFalse(PipeTryStringToIPv4('1.2.3', LAddr), 'faltando octeto');
  Assert.IsFalse(PipeTryStringToIPv4('1.2.3.4.5', LAddr), 'octeto a mais');
  Assert.IsFalse(PipeTryStringToIPv4('256.1.1.1', LAddr), 'octeto > 255');
  Assert.IsFalse(PipeTryStringToIPv4('1..2.3', LAddr), 'octeto vazio');
  Assert.IsFalse(PipeTryStringToIPv4('1.2.3.', LAddr), 'termina em ponto');
  Assert.IsFalse(PipeTryStringToIPv4('1.2.3.4 ', LAddr), 'espaco no fim');
  Assert.IsFalse(PipeTryStringToIPv4('-1.2.3.4', LAddr), 'sinal');
  Assert.IsFalse(PipeTryStringToIPv4('1.2.3.0004', LAddr),
    'mais de 3 digitos por octeto');
end;

initialization
  TDUnitX.RegisterTestFixture(TPipeDiscoveryTests);

end.
