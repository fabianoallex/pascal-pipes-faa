unit Pipes.TopicsTests;

{$mode delphi}{$H+}

{ Testes de nomes de topico, casamento hierarquico e envelope (Pipes.Topics).
  Versao FPCUnit; espelha a cobertura da versao DUnitX em tests/Unit.

  E' aqui que o roteamento do pub/sub e' garantido: a unit sob teste e' pura, e
  por isso o comportamento que decide QUEM recebe cada mensagem pode ser fixado
  sem abrir uma conexao. Os testes de integracao verificam a fiacao, nao as
  regras. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  Pipes.Types,
  Pipes.Framing,
  Pipes.Topics;

type
  TPipeTopicsTests = class(TTestCase)
  private
    FPayload: TBytes;
    procedure DoDecodeTruncado;   // PipeDecodeTopicPayload(FPayload, ...)
  published
    // --- validacao de nome literal ---
    procedure Topico_NomeSimplesEHierarquico_Valido;
    procedure Topico_Vazio_Invalido;
    procedure Topico_SegmentoVazio_Invalido;
    procedure Topico_ComCuringa_Invalido;
    procedure Topico_AcimaDoMaximoDeBytes_Invalido;
    procedure Topico_ComCaractereDeControle_Invalido;
    // --- validacao de filtro ---
    procedure Filtro_CuringasComoSegmentoInteiro_Valido;
    procedure Filtro_CuringaColadoEmTexto_Invalido;
    procedure Filtro_RestoNoMeio_Invalido;
    // --- casamento ---
    procedure Match_Exato;
    procedure Match_ExatoSensivelACaixa;
    procedure Match_UmSegmento;
    procedure Match_UmSegmentoNaoAtravessaSeparador;
    procedure Match_Resto;
    procedure Match_RestoAlcancaOPrefixoSozinho;
    procedure Match_FiltroMaisLongoQueOTopico_NaoCasa;
    procedure Match_TopicoMaisLongoQueOFiltro_NaoCasa;
    procedure Match_CuringasCombinados;
    // --- envelope ---
    procedure Envelope_RoundTrip;
    procedure Envelope_LayoutBinario;
    procedure Envelope_CorpoVazio;
    procedure Envelope_TopicoNaoAscii;
    procedure Envelope_PayloadCurto_Levanta;
    procedure Envelope_TopicLenMaiorQuePayload_Levanta;
    // --- frames ---
    procedure Frame_Publish_KindEFlagDeRetain;
    procedure Frame_SubscribeEUnsubscribe;
  end;

implementation

// Forca a sobrecarga nao-generica AssertEquals(Integer, Integer).
procedure EqualInt(AExpected, AActual: Integer);
begin
  TAssert.AssertEquals(AExpected, AActual);
end;

procedure EqualByte(AExpected: Integer; AActual: Byte);
begin
  TAssert.AssertEquals(AExpected, Integer(AActual));
end;

function MakeBytes(const AValues: array of Byte): TBytes;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(AValues));
  for I := 0 to High(AValues) do
    Result[I] := AValues[I];
end;

{ TPipeTopicsTests }

procedure TPipeTopicsTests.DoDecodeTruncado;
var
  LTopic: string;
  LBody: TBytes;
begin
  PipeDecodeTopicPayload(FPayload, LTopic, LBody);
end;

{ --- validacao de nome literal --- }

procedure TPipeTopicsTests.Topico_NomeSimplesEHierarquico_Valido;
begin
  AssertTrue(PipeIsValidTopic('status'));
  AssertTrue(PipeIsValidTopic('caixa.3.status'));
  AssertTrue(PipeIsValidTopic('a'));
end;

procedure TPipeTopicsTests.Topico_Vazio_Invalido;
begin
  AssertFalse(PipeIsValidTopic(''));
end;

procedure TPipeTopicsTests.Topico_SegmentoVazio_Invalido;
begin
  AssertFalse('ponto no inicio', PipeIsValidTopic('.caixa'));
  AssertFalse('ponto no fim', PipeIsValidTopic('caixa.'));
  AssertFalse('dois pontos seguidos', PipeIsValidTopic('caixa..status'));
  AssertFalse('so o separador', PipeIsValidTopic('.'));
end;

procedure TPipeTopicsTests.Topico_ComCuringa_Invalido;
begin
  // Quem publica nomeia UM topico. Aceitar curinga aqui seria aceitar
  // "publique em tudo que casar", que nao e' o que o fanout faz.
  AssertFalse(PipeIsValidTopic('caixa.*'));
  AssertFalse(PipeIsValidTopic('caixa.#'));
end;

procedure TPipeTopicsTests.Topico_AcimaDoMaximoDeBytes_Invalido;
begin
  AssertTrue(PipeIsValidTopic(StringOfChar('a', PIPE_MAX_TOPIC_BYTES)));
  AssertFalse(PipeIsValidTopic(StringOfChar('a', PIPE_MAX_TOPIC_BYTES + 1)));
end;

procedure TPipeTopicsTests.Topico_ComCaractereDeControle_Invalido;
begin
  AssertFalse(PipeIsValidTopic('caixa' + #10 + '.status'));
  AssertFalse(PipeIsValidTopic('caixa' + #0));
end;

{ --- validacao de filtro --- }

procedure TPipeTopicsTests.Filtro_CuringasComoSegmentoInteiro_Valido;
begin
  AssertTrue(PipeIsValidTopicFilter('caixa.*.status'));
  AssertTrue(PipeIsValidTopicFilter('caixa.#'));
  AssertTrue('assina tudo', PipeIsValidTopicFilter('#'));
  AssertTrue(PipeIsValidTopicFilter('*'));
  AssertTrue(PipeIsValidTopicFilter('*.*.#'));
  AssertTrue('filtro sem curinga', PipeIsValidTopicFilter('caixa.3.status'));
end;

procedure TPipeTopicsTests.Filtro_CuringaColadoEmTexto_Invalido;
begin
  // 'caixa*' prometeria casamento parcial dentro do segmento, que o matcher
  // nao faz — recusar e' melhor que casar nada em silencio.
  AssertFalse(PipeIsValidTopicFilter('caixa*'));
  AssertFalse(PipeIsValidTopicFilter('caixa*.status'));
  AssertFalse(PipeIsValidTopicFilter('cai#xa'));
end;

procedure TPipeTopicsTests.Filtro_RestoNoMeio_Invalido;
begin
  // As duas leituras possiveis de '#' no meio dariam resultados diferentes.
  AssertFalse(PipeIsValidTopicFilter('caixa.#.status'));
  AssertFalse(PipeIsValidTopicFilter('#.status'));
end;

{ --- casamento --- }

procedure TPipeTopicsTests.Match_Exato;
begin
  AssertTrue(PipeTopicMatches('caixa.3.status', 'caixa.3.status'));
  AssertFalse(PipeTopicMatches('caixa.3.status', 'caixa.4.status'));
end;

procedure TPipeTopicsTests.Match_ExatoSensivelACaixa;
begin
  // Nao ha upcase portatil para UTF-8; um casamento dependente de locale seria
  // pior que um sensivel a caixa.
  AssertFalse(PipeTopicMatches('Caixa.3', 'caixa.3'));
end;

procedure TPipeTopicsTests.Match_UmSegmento;
begin
  AssertTrue(PipeTopicMatches('caixa.*.status', 'caixa.3.status'));
  AssertTrue(PipeTopicMatches('*', 'status'));
  AssertTrue(PipeTopicMatches('*.*', 'caixa.3'));
end;

procedure TPipeTopicsTests.Match_UmSegmentoNaoAtravessaSeparador;
begin
  AssertFalse(PipeTopicMatches('caixa.*.status', 'caixa.3.a.status'));
  AssertFalse(PipeTopicMatches('*', 'caixa.3'));
end;

procedure TPipeTopicsTests.Match_Resto;
begin
  AssertTrue(PipeTopicMatches('caixa.#', 'caixa.3'));
  AssertTrue(PipeTopicMatches('caixa.#', 'caixa.3.status.detalhe'));
  AssertTrue(PipeTopicMatches('#', 'qualquer.coisa'));
  AssertFalse(PipeTopicMatches('caixa.#', 'loja.3'));
end;

procedure TPipeTopicsTests.Match_RestoAlcancaOPrefixoSozinho;
begin
  // '#' cobre o resto INCLUSIVE vazio: quem assina 'caixa.#' quer tudo de
  // caixa, e 'caixa' e' o proprio no.
  AssertTrue(PipeTopicMatches('caixa.#', 'caixa'));
end;

procedure TPipeTopicsTests.Match_FiltroMaisLongoQueOTopico_NaoCasa;
begin
  AssertFalse(PipeTopicMatches('caixa.3.status', 'caixa.3'));
  AssertFalse(PipeTopicMatches('caixa.*', 'caixa'));
end;

procedure TPipeTopicsTests.Match_TopicoMaisLongoQueOFiltro_NaoCasa;
begin
  AssertFalse(PipeTopicMatches('caixa.3', 'caixa.3.status'));
end;

procedure TPipeTopicsTests.Match_CuringasCombinados;
begin
  AssertTrue(PipeTopicMatches('loja.*.caixa.#', 'loja.7.caixa.3.status'));
  AssertTrue(PipeTopicMatches('loja.*.caixa.#', 'loja.7.caixa'));
  AssertFalse(PipeTopicMatches('loja.*.caixa.#', 'loja.7.terminal.3'));
end;

{ --- envelope --- }

procedure TPipeTopicsTests.Envelope_RoundTrip;
var
  LTopic: string;
  LBody: TBytes;
begin
  FPayload := PipeEncodeTopicPayload('caixa.3.status',
    MakeBytes([10, 20, 30, 40]));
  PipeDecodeTopicPayload(FPayload, LTopic, LBody);
  AssertEquals('caixa.3.status', LTopic);
  EqualInt(4, Length(LBody));
  EqualByte(10, LBody[0]);
  EqualByte(40, LBody[3]);
end;

procedure TPipeTopicsTests.Envelope_LayoutBinario;
var
  LBuf: TBytes;
begin
  // Layout no fio: u16 LE com o tamanho do topico, topico UTF-8, corpo.
  LBuf := PipeEncodeTopicPayload('ab', MakeBytes([99]));
  EqualInt(5, Length(LBuf));
  EqualByte(2, LBuf[0]);
  EqualByte(0, LBuf[1]);
  EqualByte(Ord('a'), LBuf[2]);
  EqualByte(Ord('b'), LBuf[3]);
  EqualByte(99, LBuf[4]);
end;

procedure TPipeTopicsTests.Envelope_CorpoVazio;
var
  LTopic: string;
  LBody: TBytes;
begin
  // Corpo vazio nao e' um caso degenerado: com PIPE_FLAG_RETAIN e' o que apaga
  // o valor retido de um topico.
  FPayload := PipeEncodeTopicPayload('caixa.3', nil);
  PipeDecodeTopicPayload(FPayload, LTopic, LBody);
  AssertEquals('caixa.3', LTopic);
  EqualInt(0, Length(LBody));
end;

procedure TPipeTopicsTests.Envelope_TopicoNaoAscii;
var
  LTopic: string;
  LBody, LIn, LOut: TBytes;
  I: Integer;
begin
  // O tamanho no envelope e' em BYTES UTF-8, nao em caracteres. 'secao' com
  // cedilha e til sao 7 caracteres em 9 bytes — se o campo contasse caracteres,
  // o decode leria o topico curto e o resto dele viraria corpo.
  //
  // O topico entra por BYTES (como em Pipes.FramingTests) para nao depender do
  // encoding deste arquivo-fonte nem do codepage do console.
  LIn := MakeBytes([Ord('s'), Ord('e'), $C3, $A7, $C3, $A3, Ord('o'),
    Ord('.'), Ord('x')]);
  FPayload := PipeEncodeTopicPayload(PipeUtf8Decode(LIn), MakeBytes([1]));
  EqualByte(9, FPayload[0]); // 9 bytes, nao 7 caracteres
  EqualByte(0, FPayload[1]);
  PipeDecodeTopicPayload(FPayload, LTopic, LBody);
  LOut := PipeUtf8Encode(LTopic);
  EqualInt(Length(LIn), Length(LOut));
  for I := 0 to High(LIn) do
    EqualByte(LIn[I], LOut[I]);
  EqualInt(1, Length(LBody));
end;

procedure TPipeTopicsTests.Envelope_PayloadCurto_Levanta;
begin
  FPayload := MakeBytes([5]); // 1 byte: nem o u16 do tamanho cabe
  AssertException(EPipeProtocol, DoDecodeTruncado);
end;

procedure TPipeTopicsTests.Envelope_TopicLenMaiorQuePayload_Levanta;
begin
  // Vem da rede: entrada hostil por definicao, e o decode nao pode ler alem.
  FPayload := MakeBytes([200, 0, Ord('a')]);
  AssertException(EPipeProtocol, DoDecodeTruncado);
end;

{ --- frames --- }

procedure TPipeTopicsTests.Frame_Publish_KindEFlagDeRetain;
var
  LFrame: TPipeFrame;
  LTopic: string;
  LBody: TBytes;
begin
  LFrame := PipePublishFrame('caixa.3', MakeBytes([7]), False);
  AssertTrue(LFrame.Kind = pfkPublish);
  AssertFalse(LFrame.IsRetain);
  PipeDecodeTopicPayload(LFrame.Payload, LTopic, LBody);
  AssertEquals('caixa.3', LTopic);
  EqualByte(7, LBody[0]);

  LFrame := PipePublishFrame('caixa.3', MakeBytes([7]), True);
  AssertTrue(LFrame.IsRetain);
  AssertFalse('retain e erro sao bits diferentes', LFrame.IsError);
end;

procedure TPipeTopicsTests.Frame_SubscribeEUnsubscribe;
var
  LFrame: TPipeFrame;
  LFilter: string;
  LBody: TBytes;
begin
  LFrame := PipeSubscribeFrame('caixa.#');
  AssertTrue(LFrame.Kind = pfkSubscribe);
  PipeDecodeTopicPayload(LFrame.Payload, LFilter, LBody);
  AssertEquals('caixa.#', LFilter);
  EqualInt(0, Length(LBody));

  LFrame := PipeUnsubscribeFrame('caixa.#');
  AssertTrue(LFrame.Kind = pfkUnsubscribe);
  PipeDecodeTopicPayload(LFrame.Payload, LFilter, LBody);
  AssertEquals('caixa.#', LFilter);
end;

initialization
  RegisterTest(TPipeTopicsTests);

end.
