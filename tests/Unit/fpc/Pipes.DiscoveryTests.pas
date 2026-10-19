unit Pipes.DiscoveryTests;

{$mode delphi}{$H+}

{ GENERATED FILE — produced by tools/gen_fpc_mirror.py from
  tests/Unit/Pipes.DiscoveryTests.pas (DUnitX). Do not edit by hand: edit the DUnitX
  master and run the script again. }

{ Testes do protocolo NPD1 e dos helpers IPv4 de Pipes.Discovery — so' as
  funcoes puras (encode/decode), sem socket nenhum; o caminho com rede fica no
  teste de integracao. Mestre DUnitX; o espelho FPCUnit em tests/Unit/fpc e'
  gerado por tools/gen_fpc_mirror.py. }

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
    // Alvos de AssertException: campos + metodo, nunca closure
    // (mesmo padrao do Pipes.AddressTests).
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
  TAssert.AssertEquals('sonda sem token = so o header', 6, Length(LProbe));
  TAssert.AssertTrue('sonda valida deveria decodificar', PipeDiscoveryTryDecodeProbe(LProbe, ''));
end;

procedure TPipeDiscoveryTests.Probe_RoundTrip_ComToken;
var
  LProbe: TBytes;
begin
  LProbe := PipeDiscoveryEncodeProbe('loja-03');
  TAssert.AssertTrue('token igual deveria casar', PipeDiscoveryTryDecodeProbe(LProbe, 'loja-03'));
end;

procedure TPipeDiscoveryTests.Probe_TokenErrado_Recusa;
var
  LProbe: TBytes;
begin
  LProbe := PipeDiscoveryEncodeProbe('loja-03');
  TAssert.AssertFalse('token diferente nao pode casar',
    PipeDiscoveryTryDecodeProbe(LProbe, 'loja-04'));
  TAssert.AssertFalse('token vazio nao casa com sonda com token',
    PipeDiscoveryTryDecodeProbe(LProbe, ''));
  TAssert.AssertFalse('sonda sem token nao casa com token esperado',
    PipeDiscoveryTryDecodeProbe(PipeDiscoveryEncodeProbe(''), 'loja-03'));
end;

procedure TPipeDiscoveryTests.Probe_MagicErrado_Recusa;
var
  LProbe: TBytes;
begin
  LProbe := PipeDiscoveryEncodeProbe('');
  TAssert.AssertFalse('magic corrompido nao pode decodificar',
    PipeDiscoveryTryDecodeProbe(Corrupt(LProbe, 0, Ord('X')), ''));
end;

procedure TPipeDiscoveryTests.Probe_KindDeResposta_Recusa;
var
  LResponse: TBytes;
begin
  // Uma RESPOSTA nunca pode ser aceita como sonda (senao dois responders na
  // mesma porta entrariam em loop respondendo um ao outro).
  LResponse := PipeDiscoveryEncodeResponse(5000, ptTcp, '', '');
  TAssert.AssertFalse('resposta nao e sonda', PipeDiscoveryTryDecodeProbe(LResponse, ''));
end;

procedure TPipeDiscoveryTests.Probe_ComSobra_Recusa;
var
  LProbe: TBytes;
begin
  LProbe := PipeDiscoveryEncodeProbe('tok');
  TAssert.AssertFalse('comprimento e estrito: sobra = lixo',
    PipeDiscoveryTryDecodeProbe(Resize(LProbe, 1), 'tok'));
end;

procedure TPipeDiscoveryTests.Probe_Truncada_Recusa;
var
  LProbe: TBytes;
begin
  LProbe := PipeDiscoveryEncodeProbe('tok');
  TAssert.AssertFalse('truncada nao decodifica',
    PipeDiscoveryTryDecodeProbe(Resize(LProbe, -1), 'tok'));
  TAssert.AssertFalse('datagrama vazio nao decodifica',
    PipeDiscoveryTryDecodeProbe(Resize(LProbe, -Length(LProbe)),
    'tok'));
end;

procedure TPipeDiscoveryTests.Probe_TokenLongoDemais_Levanta;
begin
  FToken := StringOfChar('x', PIPES_DISCOVERY_MAX_TOKEN_BYTES + 1);
  TAssert.AssertException('token acima do teto', EPipeError, DoEncodeProbe);
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
  TAssert.AssertTrue('resposta valida deveria decodificar',
    PipeDiscoveryTryDecodeResponse(LResp, 'loja-03', LPort,
    LTransport, LName));
  TAssert.AssertEquals('porta preservada', 5000, LPort);
  TAssert.AssertTrue('transporte preservado', LTransport = ptTls);
  TAssert.AssertEquals('nome preservado', 'Retaguarda Loja 3', LName);
end;

procedure TPipeDiscoveryTests.Response_RoundTrip_NomeVazioETokenVazio;
var
  LResp: TBytes;
  LPort: Word;
  LTransport: TPipeTransport;
  LName: string;
begin
  LResp := PipeDiscoveryEncodeResponse(65535, ptLocal, '', '');
  TAssert.AssertTrue('nome e token vazios sao validos',
    PipeDiscoveryTryDecodeResponse(LResp, '', LPort, LTransport,
    LName));
  TAssert.AssertEquals('porta maxima preservada', 65535, LPort);
  TAssert.AssertTrue('transporte preservado', LTransport = ptLocal);
  TAssert.AssertEquals('nome vazio preservado', '', LName);
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
  TAssert.AssertTrue('nome UTF-8 deveria decodificar',
    PipeDiscoveryTryDecodeResponse(LResp, '', LPort, LTransport,
    LName));
  TAssert.AssertEquals('nome multibyte preservado', NOME_ACENTUADO, LName);
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
  TAssert.AssertTrue('nome exatamente no teto e valido',
    PipeDiscoveryTryDecodeResponse(LResp, '', LPort, LTransport,
    LName));
  TAssert.AssertEquals('nome no limite preservado', PIPES_DISCOVERY_MAX_NAME_BYTES, Length(LName));
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
  TAssert.AssertFalse('transporte de versao futura: recusa, nao adivinha',
    PipeDiscoveryTryDecodeResponse(Corrupt(LResp, 8, 250), '',
    LPort, LTransport, LName));
end;

procedure TPipeDiscoveryTests.Response_ComSobra_Recusa;
var
  LResp: TBytes;
  LPort: Word;
  LTransport: TPipeTransport;
  LName: string;
begin
  LResp := PipeDiscoveryEncodeResponse(5000, ptTcp, 'srv', '');
  TAssert.AssertFalse('comprimento e estrito: sobra = lixo',
    PipeDiscoveryTryDecodeResponse(Resize(LResp, 3), '', LPort,
    LTransport, LName));
end;

procedure TPipeDiscoveryTests.Response_Truncada_Recusa;
var
  LResp: TBytes;
  LPort: Word;
  LTransport: TPipeTransport;
  LName: string;
begin
  LResp := PipeDiscoveryEncodeResponse(5000, ptTcp, 'srv', '');
  TAssert.AssertFalse('nome anunciado maior que o datagrama',
    PipeDiscoveryTryDecodeResponse(Resize(LResp, -1), '', LPort,
    LTransport, LName));
  TAssert.AssertFalse('corpo truncado',
    PipeDiscoveryTryDecodeResponse(Resize(LResp, -4), '', LPort,
    LTransport, LName));
end;

procedure TPipeDiscoveryTests.Response_TokenErrado_Recusa;
var
  LResp: TBytes;
  LPort: Word;
  LTransport: TPipeTransport;
  LName: string;
begin
  LResp := PipeDiscoveryEncodeResponse(5000, ptTcp, '', 'loja-03');
  TAssert.AssertFalse('resposta de outra instalacao nao entra na lista',
    PipeDiscoveryTryDecodeResponse(LResp, 'loja-04', LPort,
    LTransport, LName));
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
  TAssert.AssertFalse('porta 0 no fio e recusada',
    PipeDiscoveryTryDecodeResponse(LResp, '', LPort, LTransport,
    LName));
end;

procedure TPipeDiscoveryTests.Encode_PortaZero_Levanta;
begin
  FPort := 0;
  FName := '';
  FToken := '';
  TAssert.AssertException('porta 0 nao e anunciavel', EPipeError, DoEncodeResponse);
end;

procedure TPipeDiscoveryTests.Encode_NomeLongoDemais_Levanta;
begin
  FPort := 5000;
  FName := StringOfChar('n', PIPES_DISCOVERY_MAX_NAME_BYTES + 1);
  FToken := '';
  TAssert.AssertException('nome acima do teto', EPipeError, DoEncodeResponse);
end;

procedure TPipeDiscoveryTests.Ipv4_RoundTrip;
var
  LAddr: LongWord;
begin
  TAssert.AssertTrue('192.168.1.10', PipeTryStringToIPv4('192.168.1.10', LAddr));
  TAssert.AssertEquals('roundtrip', '192.168.1.10', PipeIPv4ToString(LAddr));
  TAssert.AssertTrue('0.0.0.0', PipeTryStringToIPv4('0.0.0.0', LAddr));
  TAssert.AssertEquals('roundtrip zeros', '0.0.0.0', PipeIPv4ToString(LAddr));
  TAssert.AssertTrue('broadcast', PipeTryStringToIPv4('255.255.255.255', LAddr));
  TAssert.AssertEquals('roundtrip broadcast', '255.255.255.255', PipeIPv4ToString(LAddr));
end;

procedure TPipeDiscoveryTests.Ipv4_OrdemDeRede;
var
  LAddr: LongWord;
begin
  // Em ordem de rede num host little-endian, 1.2.3.4 = $04030201 (primeiro
  // octeto no byte mais baixo) — e' o layout que sin_addr espera.
  TAssert.AssertTrue('1.2.3.4', PipeTryStringToIPv4('1.2.3.4', LAddr));
  // Comparado via AssertTrue: LongWord nao tem sobrecarga de AssertEquals.
  TAssert.AssertTrue('layout de sin_addr', LAddr = LongWord($04030201));
  TAssert.AssertEquals('volta do mesmo valor', '1.2.3.4', PipeIPv4ToString(LongWord($04030201)));
end;

procedure TPipeDiscoveryTests.Ipv4_LiteraisInvalidos_Recusa;
var
  LAddr: LongWord;
begin
  TAssert.AssertFalse('vazio', PipeTryStringToIPv4('', LAddr));
  TAssert.AssertFalse('nome de host', PipeTryStringToIPv4('servidor01', LAddr));
  TAssert.AssertFalse('faltando octeto', PipeTryStringToIPv4('1.2.3', LAddr));
  TAssert.AssertFalse('octeto a mais', PipeTryStringToIPv4('1.2.3.4.5', LAddr));
  TAssert.AssertFalse('octeto > 255', PipeTryStringToIPv4('256.1.1.1', LAddr));
  TAssert.AssertFalse('octeto vazio', PipeTryStringToIPv4('1..2.3', LAddr));
  TAssert.AssertFalse('termina em ponto', PipeTryStringToIPv4('1.2.3.', LAddr));
  TAssert.AssertFalse('espaco no fim', PipeTryStringToIPv4('1.2.3.4 ', LAddr));
  TAssert.AssertFalse('sinal', PipeTryStringToIPv4('-1.2.3.4', LAddr));
  TAssert.AssertFalse('mais de 3 digitos por octeto', PipeTryStringToIPv4('1.2.3.0004', LAddr));
end;

initialization
  RegisterTest(TPipeDiscoveryTests);

end.
