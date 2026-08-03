unit Pipes.DiscoveryTests;

{$mode delphi}{$H+}

{ Testes do protocolo NPD1 e dos helpers IPv4 de Pipes.Discovery — so' as
  funcoes puras (encode/decode), sem socket nenhum; o caminho com rede fica no
  teste de integracao. Versao FPCUnit; espelha a cobertura da versao DUnitX em
  tests/Unit. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  Pipes.Types,
  Pipes.Discovery;

type
  TPipeDiscoveryTests = class(TTestCase)
  private
    FToken: string;
    FName: string;
    FPort: Word;
    // Alvos dos AssertException: campos + metodo, nunca closure (mesmo
    // padrao do Pipes.AddressTests, que mantem o espelho Delphi 1:1).
    procedure DoEncodeProbe;
    procedure DoEncodeResponse;
    /// Copia ADatagram com o byte AIndex substituido por AValue.
    function Corrupt(const ADatagram: TBytes; AIndex: Integer;
      AValue: Byte): TBytes;
    /// Copia ADatagram com ADelta bytes a mais (zerados) ou a menos.
    function Resize(const ADatagram: TBytes; ADelta: Integer): TBytes;
  published
    procedure Probe_RoundTrip_SemToken;
    procedure Probe_RoundTrip_ComToken;
    procedure Probe_TokenErrado_Recusa;
    procedure Probe_MagicErrado_Recusa;
    procedure Probe_KindDeResposta_Recusa;
    procedure Probe_ComSobra_Recusa;
    procedure Probe_Truncada_Recusa;
    procedure Probe_TokenLongoDemais_Levanta;
    procedure Response_RoundTrip;
    procedure Response_RoundTrip_NomeVazioETokenVazio;
    procedure Response_RoundTrip_NomeUtf8;
    procedure Response_NomeNoLimite_RoundTrip;
    procedure Response_TransporteDesconhecido_Recusa;
    procedure Response_ComSobra_Recusa;
    procedure Response_Truncada_Recusa;
    procedure Response_TokenErrado_Recusa;
    procedure Response_PortaZero_Recusa;
    procedure Encode_PortaZero_Levanta;
    procedure Encode_NomeLongoDemais_Levanta;
    procedure Ipv4_RoundTrip;
    procedure Ipv4_OrdemDeRede;
    procedure Ipv4_LiteraisInvalidos_Recusa;
  end;

implementation

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
  AssertEquals('sonda sem token = so o header', 6, Length(LProbe));
  AssertTrue('sonda valida deveria decodificar',
    PipeDiscoveryTryDecodeProbe(LProbe, ''));
end;

procedure TPipeDiscoveryTests.Probe_RoundTrip_ComToken;
var
  LProbe: TBytes;
begin
  LProbe := PipeDiscoveryEncodeProbe('loja-03');
  AssertTrue('token igual deveria casar',
    PipeDiscoveryTryDecodeProbe(LProbe, 'loja-03'));
end;

procedure TPipeDiscoveryTests.Probe_TokenErrado_Recusa;
var
  LProbe: TBytes;
begin
  LProbe := PipeDiscoveryEncodeProbe('loja-03');
  AssertFalse('token diferente nao pode casar',
    PipeDiscoveryTryDecodeProbe(LProbe, 'loja-04'));
  AssertFalse('token vazio nao casa com sonda com token',
    PipeDiscoveryTryDecodeProbe(LProbe, ''));
  AssertFalse('sonda sem token nao casa com token esperado',
    PipeDiscoveryTryDecodeProbe(PipeDiscoveryEncodeProbe(''), 'loja-03'));
end;

procedure TPipeDiscoveryTests.Probe_MagicErrado_Recusa;
var
  LProbe: TBytes;
begin
  LProbe := PipeDiscoveryEncodeProbe('');
  AssertFalse('magic corrompido nao pode decodificar',
    PipeDiscoveryTryDecodeProbe(Corrupt(LProbe, 0, Ord('X')), ''));
end;

procedure TPipeDiscoveryTests.Probe_KindDeResposta_Recusa;
var
  LResponse: TBytes;
begin
  // Uma RESPOSTA nunca pode ser aceita como sonda (senao dois responders na
  // mesma porta entrariam em loop respondendo um ao outro).
  LResponse := PipeDiscoveryEncodeResponse(5000, ptTcp, '', '');
  AssertFalse('resposta nao e sonda',
    PipeDiscoveryTryDecodeProbe(LResponse, ''));
end;

procedure TPipeDiscoveryTests.Probe_ComSobra_Recusa;
var
  LProbe: TBytes;
begin
  LProbe := PipeDiscoveryEncodeProbe('tok');
  AssertFalse('comprimento e estrito: sobra = lixo',
    PipeDiscoveryTryDecodeProbe(Resize(LProbe, 1), 'tok'));
end;

procedure TPipeDiscoveryTests.Probe_Truncada_Recusa;
var
  LProbe: TBytes;
begin
  LProbe := PipeDiscoveryEncodeProbe('tok');
  AssertFalse('truncada nao decodifica',
    PipeDiscoveryTryDecodeProbe(Resize(LProbe, -1), 'tok'));
  AssertFalse('datagrama vazio nao decodifica',
    PipeDiscoveryTryDecodeProbe(Resize(LProbe, -Length(LProbe)), 'tok'));
end;

procedure TPipeDiscoveryTests.Probe_TokenLongoDemais_Levanta;
begin
  FToken := StringOfChar('x', PIPES_DISCOVERY_MAX_TOKEN_BYTES + 1);
  AssertException('token acima do teto', EPipeError, DoEncodeProbe);
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
  AssertTrue('resposta valida deveria decodificar',
    PipeDiscoveryTryDecodeResponse(LResp, 'loja-03', LPort, LTransport,
      LName));
  AssertEquals('porta preservada', 5000, Integer(LPort));
  AssertTrue('transporte preservado', LTransport = ptTls);
  AssertEquals('nome preservado', 'Retaguarda Loja 3', LName);
end;

procedure TPipeDiscoveryTests.Response_RoundTrip_NomeVazioETokenVazio;
var
  LResp: TBytes;
  LPort: Word;
  LTransport: TPipeTransport;
  LName: string;
begin
  LResp := PipeDiscoveryEncodeResponse(65535, ptLocal, '', '');
  AssertTrue('nome e token vazios sao validos',
    PipeDiscoveryTryDecodeResponse(LResp, '', LPort, LTransport, LName));
  AssertEquals('porta maxima preservada', 65535, Integer(LPort));
  AssertTrue('transporte preservado', LTransport = ptLocal);
  AssertEquals('nome vazio preservado', '', LName);
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
  AssertTrue('nome UTF-8 deveria decodificar',
    PipeDiscoveryTryDecodeResponse(LResp, '', LPort, LTransport, LName));
  AssertEquals('nome multibyte preservado', NOME_ACENTUADO, LName);
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
  AssertTrue('nome exatamente no teto e valido',
    PipeDiscoveryTryDecodeResponse(LResp, '', LPort, LTransport, LName));
  AssertEquals('nome no limite preservado', PIPES_DISCOVERY_MAX_NAME_BYTES,
    Length(LName));
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
  AssertFalse('transporte de versao futura: recusa, nao adivinha',
    PipeDiscoveryTryDecodeResponse(Corrupt(LResp, 8, 250), '', LPort,
      LTransport, LName));
end;

procedure TPipeDiscoveryTests.Response_ComSobra_Recusa;
var
  LResp: TBytes;
  LPort: Word;
  LTransport: TPipeTransport;
  LName: string;
begin
  LResp := PipeDiscoveryEncodeResponse(5000, ptTcp, 'srv', '');
  AssertFalse('comprimento e estrito: sobra = lixo',
    PipeDiscoveryTryDecodeResponse(Resize(LResp, 3), '', LPort, LTransport,
      LName));
end;

procedure TPipeDiscoveryTests.Response_Truncada_Recusa;
var
  LResp: TBytes;
  LPort: Word;
  LTransport: TPipeTransport;
  LName: string;
begin
  LResp := PipeDiscoveryEncodeResponse(5000, ptTcp, 'srv', '');
  AssertFalse('nome anunciado maior que o datagrama',
    PipeDiscoveryTryDecodeResponse(Resize(LResp, -1), '', LPort, LTransport,
      LName));
  AssertFalse('corpo truncado',
    PipeDiscoveryTryDecodeResponse(Resize(LResp, -4), '', LPort, LTransport,
      LName));
end;

procedure TPipeDiscoveryTests.Response_TokenErrado_Recusa;
var
  LResp: TBytes;
  LPort: Word;
  LTransport: TPipeTransport;
  LName: string;
begin
  LResp := PipeDiscoveryEncodeResponse(5000, ptTcp, '', 'loja-03');
  AssertFalse('resposta de outra instalacao nao entra na lista',
    PipeDiscoveryTryDecodeResponse(LResp, 'loja-04', LPort, LTransport,
      LName));
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
  AssertFalse('porta 0 no fio e recusada',
    PipeDiscoveryTryDecodeResponse(LResp, '', LPort, LTransport, LName));
end;

procedure TPipeDiscoveryTests.Encode_PortaZero_Levanta;
begin
  FPort := 0;
  FName := '';
  FToken := '';
  AssertException('porta 0 nao e anunciavel', EPipeError, DoEncodeResponse);
end;

procedure TPipeDiscoveryTests.Encode_NomeLongoDemais_Levanta;
begin
  FPort := 5000;
  FName := StringOfChar('n', PIPES_DISCOVERY_MAX_NAME_BYTES + 1);
  FToken := '';
  AssertException('nome acima do teto', EPipeError, DoEncodeResponse);
end;

procedure TPipeDiscoveryTests.Ipv4_RoundTrip;
var
  LAddr: LongWord;
begin
  AssertTrue('192.168.1.10', PipeTryStringToIPv4('192.168.1.10', LAddr));
  AssertEquals('roundtrip', '192.168.1.10', PipeIPv4ToString(LAddr));
  AssertTrue('0.0.0.0', PipeTryStringToIPv4('0.0.0.0', LAddr));
  AssertEquals('roundtrip zeros', '0.0.0.0', PipeIPv4ToString(LAddr));
  AssertTrue('broadcast', PipeTryStringToIPv4('255.255.255.255', LAddr));
  AssertEquals('roundtrip broadcast', '255.255.255.255',
    PipeIPv4ToString(LAddr));
end;

procedure TPipeDiscoveryTests.Ipv4_OrdemDeRede;
var
  LAddr: LongWord;
begin
  AssertTrue('1.2.3.4', PipeTryStringToIPv4('1.2.3.4', LAddr));
  // Comparado via AssertTrue: AssertEquals nao tem overload de LongWord
  // (mesma razao do IsTrue na versao Delphi).
  AssertTrue('layout de sin_addr', LAddr = LongWord($04030201));
  AssertEquals('volta do mesmo valor', '1.2.3.4',
    PipeIPv4ToString(LongWord($04030201)));
end;

procedure TPipeDiscoveryTests.Ipv4_LiteraisInvalidos_Recusa;
var
  LAddr: LongWord;
begin
  AssertFalse('vazio', PipeTryStringToIPv4('', LAddr));
  AssertFalse('nome de host', PipeTryStringToIPv4('servidor01', LAddr));
  AssertFalse('faltando octeto', PipeTryStringToIPv4('1.2.3', LAddr));
  AssertFalse('octeto a mais', PipeTryStringToIPv4('1.2.3.4.5', LAddr));
  AssertFalse('octeto > 255', PipeTryStringToIPv4('256.1.1.1', LAddr));
  AssertFalse('octeto vazio', PipeTryStringToIPv4('1..2.3', LAddr));
  AssertFalse('termina em ponto', PipeTryStringToIPv4('1.2.3.', LAddr));
  AssertFalse('espaco no fim', PipeTryStringToIPv4('1.2.3.4 ', LAddr));
  AssertFalse('sinal', PipeTryStringToIPv4('-1.2.3.4', LAddr));
  AssertFalse('mais de 3 digitos por octeto',
    PipeTryStringToIPv4('1.2.3.0004', LAddr));
end;

initialization
  RegisterTest(TPipeDiscoveryTests);

end.
