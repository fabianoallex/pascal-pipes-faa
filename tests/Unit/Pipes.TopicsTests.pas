unit Pipes.TopicsTests;

{ Testes de nomes de topico, casamento hierarquico e envelope (Pipes.Topics).
  Versao DUnitX/Delphi; a versao FPCUnit em tests/Unit/fpc espelha a mesma
  cobertura.

  E' aqui que o roteamento do pub/sub e' garantido: a unit sob teste e' pura, e
  por isso o comportamento que decide QUEM recebe cada mensagem pode ser fixado
  sem abrir uma conexao. Os testes de integracao verificam a fiacao, nao as
  regras. }

interface

uses
  DUnitX.TestFramework,
  SysUtils,
  Pipes.Types,
  Pipes.Framing,
  Pipes.Topics;

type
  [TestFixture]
  TPipeTopicsTests = class
  private
    FPayload: TBytes;
    procedure DoDecodeTruncado;   // PipeDecodeTopicPayload(FPayload, ...)
  published
    // --- validacao de nome literal ---
    [Test] procedure Topico_NomeSimplesEHierarquico_Valido;
    [Test] procedure Topico_Vazio_Invalido;
    [Test] procedure Topico_SegmentoVazio_Invalido;
    [Test] procedure Topico_ComCuringa_Invalido;
    [Test] procedure Topico_AcimaDoMaximoDeBytes_Invalido;
    [Test] procedure Topico_ComCaractereDeControle_Invalido;
    // --- validacao de filtro ---
    [Test] procedure Filtro_CuringasComoSegmentoInteiro_Valido;
    [Test] procedure Filtro_CuringaColadoEmTexto_Invalido;
    [Test] procedure Filtro_RestoNoMeio_Invalido;
    // --- casamento ---
    [Test] procedure Match_Exato;
    [Test] procedure Match_ExatoSensivelACaixa;
    [Test] procedure Match_UmSegmento;
    [Test] procedure Match_UmSegmentoNaoAtravessaSeparador;
    [Test] procedure Match_Resto;
    [Test] procedure Match_RestoAlcancaOPrefixoSozinho;
    [Test] procedure Match_FiltroMaisLongoQueOTopico_NaoCasa;
    [Test] procedure Match_TopicoMaisLongoQueOFiltro_NaoCasa;
    [Test] procedure Match_CuringasCombinados;
    // --- envelope ---
    [Test] procedure Envelope_RoundTrip;
    [Test] procedure Envelope_LayoutBinario;
    [Test] procedure Envelope_CorpoVazio;
    [Test] procedure Envelope_TopicoNaoAscii;
    [Test] procedure Envelope_PayloadCurto_Levanta;
    [Test] procedure Envelope_TopicLenMaiorQuePayload_Levanta;
    // --- frames ---
    [Test] procedure Frame_Publish_KindEFlagDeRetain;
    [Test] procedure Frame_SubscribeEUnsubscribe;
  end;

implementation

// Length() e' NativeInt no Win64 e AreEqual<T> nao infere T com argumentos de
// tipos diferentes (E2532) — mesmo motivo do helper em Pipes.FramingTests.
procedure EqualInt(AExpected, AActual: Integer);
begin
  Assert.AreEqual(AExpected, AActual);
end;

procedure EqualByte(AExpected: Integer; AActual: Byte);
begin
  Assert.AreEqual(AExpected, Integer(AActual));
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
  Assert.IsTrue(PipeIsValidTopic('status'));
  Assert.IsTrue(PipeIsValidTopic('caixa.3.status'));
  Assert.IsTrue(PipeIsValidTopic('a'));
end;

procedure TPipeTopicsTests.Topico_Vazio_Invalido;
begin
  Assert.IsFalse(PipeIsValidTopic(''));
end;

procedure TPipeTopicsTests.Topico_SegmentoVazio_Invalido;
begin
  Assert.IsFalse(PipeIsValidTopic('.caixa'), 'ponto no inicio');
  Assert.IsFalse(PipeIsValidTopic('caixa.'), 'ponto no fim');
  Assert.IsFalse(PipeIsValidTopic('caixa..status'), 'dois pontos seguidos');
  Assert.IsFalse(PipeIsValidTopic('.'), 'so o separador');
end;

procedure TPipeTopicsTests.Topico_ComCuringa_Invalido;
begin
  // Quem publica nomeia UM topico. Aceitar curinga aqui seria aceitar
  // "publique em tudo que casar", que nao e' o que o fanout faz.
  Assert.IsFalse(PipeIsValidTopic('caixa.*'));
  Assert.IsFalse(PipeIsValidTopic('caixa.#'));
end;

procedure TPipeTopicsTests.Topico_AcimaDoMaximoDeBytes_Invalido;
begin
  Assert.IsTrue(PipeIsValidTopic(StringOfChar('a', PIPE_MAX_TOPIC_BYTES)));
  Assert.IsFalse(PipeIsValidTopic(StringOfChar('a', PIPE_MAX_TOPIC_BYTES + 1)));
end;

procedure TPipeTopicsTests.Topico_ComCaractereDeControle_Invalido;
begin
  Assert.IsFalse(PipeIsValidTopic('caixa' + #10 + '.status'));
  Assert.IsFalse(PipeIsValidTopic('caixa' + #0));
end;

{ --- validacao de filtro --- }

procedure TPipeTopicsTests.Filtro_CuringasComoSegmentoInteiro_Valido;
begin
  Assert.IsTrue(PipeIsValidTopicFilter('caixa.*.status'));
  Assert.IsTrue(PipeIsValidTopicFilter('caixa.#'));
  Assert.IsTrue(PipeIsValidTopicFilter('#'), 'assina tudo');
  Assert.IsTrue(PipeIsValidTopicFilter('*'));
  Assert.IsTrue(PipeIsValidTopicFilter('*.*.#'));
  Assert.IsTrue(PipeIsValidTopicFilter('caixa.3.status'), 'filtro sem curinga');
end;

procedure TPipeTopicsTests.Filtro_CuringaColadoEmTexto_Invalido;
begin
  // 'caixa*' prometeria casamento parcial dentro do segmento, que o matcher
  // nao faz — recusar e' melhor que casar nada em silencio.
  Assert.IsFalse(PipeIsValidTopicFilter('caixa*'));
  Assert.IsFalse(PipeIsValidTopicFilter('caixa*.status'));
  Assert.IsFalse(PipeIsValidTopicFilter('cai#xa'));
end;

procedure TPipeTopicsTests.Filtro_RestoNoMeio_Invalido;
begin
  // As duas leituras possiveis de '#' no meio dariam resultados diferentes.
  Assert.IsFalse(PipeIsValidTopicFilter('caixa.#.status'));
  Assert.IsFalse(PipeIsValidTopicFilter('#.status'));
end;

{ --- casamento --- }

procedure TPipeTopicsTests.Match_Exato;
begin
  Assert.IsTrue(PipeTopicMatches('caixa.3.status', 'caixa.3.status'));
  Assert.IsFalse(PipeTopicMatches('caixa.3.status', 'caixa.4.status'));
end;

procedure TPipeTopicsTests.Match_ExatoSensivelACaixa;
begin
  // Nao ha upcase portatil para UTF-8; um casamento dependente de locale seria
  // pior que um sensivel a caixa.
  Assert.IsFalse(PipeTopicMatches('Caixa.3', 'caixa.3'));
end;

procedure TPipeTopicsTests.Match_UmSegmento;
begin
  Assert.IsTrue(PipeTopicMatches('caixa.*.status', 'caixa.3.status'));
  Assert.IsTrue(PipeTopicMatches('*', 'status'));
  Assert.IsTrue(PipeTopicMatches('*.*', 'caixa.3'));
end;

procedure TPipeTopicsTests.Match_UmSegmentoNaoAtravessaSeparador;
begin
  Assert.IsFalse(PipeTopicMatches('caixa.*.status', 'caixa.3.a.status'));
  Assert.IsFalse(PipeTopicMatches('*', 'caixa.3'));
end;

procedure TPipeTopicsTests.Match_Resto;
begin
  Assert.IsTrue(PipeTopicMatches('caixa.#', 'caixa.3'));
  Assert.IsTrue(PipeTopicMatches('caixa.#', 'caixa.3.status.detalhe'));
  Assert.IsTrue(PipeTopicMatches('#', 'qualquer.coisa'));
  Assert.IsFalse(PipeTopicMatches('caixa.#', 'loja.3'));
end;

procedure TPipeTopicsTests.Match_RestoAlcancaOPrefixoSozinho;
begin
  // '#' cobre o resto INCLUSIVE vazio: quem assina 'caixa.#' quer tudo de
  // caixa, e 'caixa' e' o proprio no.
  Assert.IsTrue(PipeTopicMatches('caixa.#', 'caixa'));
end;

procedure TPipeTopicsTests.Match_FiltroMaisLongoQueOTopico_NaoCasa;
begin
  Assert.IsFalse(PipeTopicMatches('caixa.3.status', 'caixa.3'));
  Assert.IsFalse(PipeTopicMatches('caixa.*', 'caixa'));
end;

procedure TPipeTopicsTests.Match_TopicoMaisLongoQueOFiltro_NaoCasa;
begin
  Assert.IsFalse(PipeTopicMatches('caixa.3', 'caixa.3.status'));
end;

procedure TPipeTopicsTests.Match_CuringasCombinados;
begin
  Assert.IsTrue(PipeTopicMatches('loja.*.caixa.#', 'loja.7.caixa.3.status'));
  Assert.IsTrue(PipeTopicMatches('loja.*.caixa.#', 'loja.7.caixa'));
  Assert.IsFalse(PipeTopicMatches('loja.*.caixa.#', 'loja.7.terminal.3'));
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
  Assert.AreEqual('caixa.3.status', LTopic);
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
  Assert.AreEqual('caixa.3', LTopic);
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
  Assert.WillRaise(DoDecodeTruncado, EPipeProtocol);
end;

procedure TPipeTopicsTests.Envelope_TopicLenMaiorQuePayload_Levanta;
begin
  // Vem da rede: entrada hostil por definicao, e o decode nao pode ler alem.
  FPayload := MakeBytes([200, 0, Ord('a')]);
  Assert.WillRaise(DoDecodeTruncado, EPipeProtocol);
end;

{ --- frames --- }

procedure TPipeTopicsTests.Frame_Publish_KindEFlagDeRetain;
var
  LFrame: TPipeFrame;
  LTopic: string;
  LBody: TBytes;
begin
  LFrame := PipePublishFrame('caixa.3', MakeBytes([7]), False);
  Assert.IsTrue(LFrame.Kind = pfkPublish);
  Assert.IsFalse(LFrame.IsRetain);
  PipeDecodeTopicPayload(LFrame.Payload, LTopic, LBody);
  Assert.AreEqual('caixa.3', LTopic);
  EqualByte(7, LBody[0]);

  LFrame := PipePublishFrame('caixa.3', MakeBytes([7]), True);
  Assert.IsTrue(LFrame.IsRetain);
  Assert.IsFalse(LFrame.IsError, 'retain e erro sao bits diferentes');
end;

procedure TPipeTopicsTests.Frame_SubscribeEUnsubscribe;
var
  LFrame: TPipeFrame;
  LFilter: string;
  LBody: TBytes;
begin
  LFrame := PipeSubscribeFrame('caixa.#');
  Assert.IsTrue(LFrame.Kind = pfkSubscribe);
  PipeDecodeTopicPayload(LFrame.Payload, LFilter, LBody);
  Assert.AreEqual('caixa.#', LFilter);
  EqualInt(0, Length(LBody));

  LFrame := PipeUnsubscribeFrame('caixa.#');
  Assert.IsTrue(LFrame.Kind = pfkUnsubscribe);
  PipeDecodeTopicPayload(LFrame.Payload, LFilter, LBody);
  Assert.AreEqual('caixa.#', LFilter);
end;

initialization
  TDUnitX.RegisterTestFixture(TPipeTopicsTests);

end.
