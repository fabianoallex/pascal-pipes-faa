unit Pipes.TopicsTests;

{$mode delphi}{$H+}

{ GENERATED FILE — produced by tools/gen_fpc_mirror.py from
  tests/Unit/Pipes.TopicsTests.pas (DUnitX). Do not edit by hand: edit the DUnitX
  master and run the script again. }

{ Testes de nomes de topico, casamento hierarquico e envelope (Pipes.Topics).
  Mestre DUnitX; o espelho FPCUnit em tests/Unit/fpc e' gerado por
  tools/gen_fpc_mirror.py.

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
  TAssert.AssertTrue(PipeIsValidTopic('status'));
  TAssert.AssertTrue(PipeIsValidTopic('caixa.3.status'));
  TAssert.AssertTrue(PipeIsValidTopic('a'));
end;

procedure TPipeTopicsTests.Topico_Vazio_Invalido;
begin
  TAssert.AssertFalse(PipeIsValidTopic(''));
end;

procedure TPipeTopicsTests.Topico_SegmentoVazio_Invalido;
begin
  TAssert.AssertFalse('ponto no inicio', PipeIsValidTopic('.caixa'));
  TAssert.AssertFalse('ponto no fim', PipeIsValidTopic('caixa.'));
  TAssert.AssertFalse('dois pontos seguidos', PipeIsValidTopic('caixa..status'));
  TAssert.AssertFalse('so o separador', PipeIsValidTopic('.'));
end;

procedure TPipeTopicsTests.Topico_ComCuringa_Invalido;
begin
  // Quem publica nomeia UM topico. Aceitar curinga aqui seria aceitar
  // "publique em tudo que casar", que nao e' o que o fanout faz.
  TAssert.AssertFalse(PipeIsValidTopic('caixa.*'));
  TAssert.AssertFalse(PipeIsValidTopic('caixa.#'));
end;

procedure TPipeTopicsTests.Topico_AcimaDoMaximoDeBytes_Invalido;
begin
  TAssert.AssertTrue(PipeIsValidTopic(StringOfChar('a', PIPE_MAX_TOPIC_BYTES)));
  TAssert.AssertFalse(PipeIsValidTopic(StringOfChar('a', PIPE_MAX_TOPIC_BYTES + 1)));
end;

procedure TPipeTopicsTests.Topico_ComCaractereDeControle_Invalido;
begin
  TAssert.AssertFalse(PipeIsValidTopic('caixa' + #10 + '.status'));
  TAssert.AssertFalse(PipeIsValidTopic('caixa' + #0));
end;

{ --- validacao de filtro --- }

procedure TPipeTopicsTests.Filtro_CuringasComoSegmentoInteiro_Valido;
begin
  TAssert.AssertTrue(PipeIsValidTopicFilter('caixa.*.status'));
  TAssert.AssertTrue(PipeIsValidTopicFilter('caixa.#'));
  TAssert.AssertTrue('assina tudo', PipeIsValidTopicFilter('#'));
  TAssert.AssertTrue(PipeIsValidTopicFilter('*'));
  TAssert.AssertTrue(PipeIsValidTopicFilter('*.*.#'));
  TAssert.AssertTrue('filtro sem curinga', PipeIsValidTopicFilter('caixa.3.status'));
end;

procedure TPipeTopicsTests.Filtro_CuringaColadoEmTexto_Invalido;
begin
  // 'caixa*' prometeria casamento parcial dentro do segmento, que o matcher
  // nao faz — recusar e' melhor que casar nada em silencio.
  TAssert.AssertFalse(PipeIsValidTopicFilter('caixa*'));
  TAssert.AssertFalse(PipeIsValidTopicFilter('caixa*.status'));
  TAssert.AssertFalse(PipeIsValidTopicFilter('cai#xa'));
end;

procedure TPipeTopicsTests.Filtro_RestoNoMeio_Invalido;
begin
  // As duas leituras possiveis de '#' no meio dariam resultados diferentes.
  TAssert.AssertFalse(PipeIsValidTopicFilter('caixa.#.status'));
  TAssert.AssertFalse(PipeIsValidTopicFilter('#.status'));
end;

{ --- casamento --- }

procedure TPipeTopicsTests.Match_Exato;
begin
  TAssert.AssertTrue(PipeTopicMatches('caixa.3.status', 'caixa.3.status'));
  TAssert.AssertFalse(PipeTopicMatches('caixa.3.status', 'caixa.4.status'));
end;

procedure TPipeTopicsTests.Match_ExatoSensivelACaixa;
begin
  // Nao ha upcase portatil para UTF-8; um casamento dependente de locale seria
  // pior que um sensivel a caixa.
  TAssert.AssertFalse(PipeTopicMatches('Caixa.3', 'caixa.3'));
end;

procedure TPipeTopicsTests.Match_UmSegmento;
begin
  TAssert.AssertTrue(PipeTopicMatches('caixa.*.status', 'caixa.3.status'));
  TAssert.AssertTrue(PipeTopicMatches('*', 'status'));
  TAssert.AssertTrue(PipeTopicMatches('*.*', 'caixa.3'));
end;

procedure TPipeTopicsTests.Match_UmSegmentoNaoAtravessaSeparador;
begin
  TAssert.AssertFalse(PipeTopicMatches('caixa.*.status', 'caixa.3.a.status'));
  TAssert.AssertFalse(PipeTopicMatches('*', 'caixa.3'));
end;

procedure TPipeTopicsTests.Match_Resto;
begin
  TAssert.AssertTrue(PipeTopicMatches('caixa.#', 'caixa.3'));
  TAssert.AssertTrue(PipeTopicMatches('caixa.#', 'caixa.3.status.detalhe'));
  TAssert.AssertTrue(PipeTopicMatches('#', 'qualquer.coisa'));
  TAssert.AssertFalse(PipeTopicMatches('caixa.#', 'loja.3'));
end;

procedure TPipeTopicsTests.Match_RestoAlcancaOPrefixoSozinho;
begin
  // '#' cobre o resto INCLUSIVE vazio: quem assina 'caixa.#' quer tudo de
  // caixa, e 'caixa' e' o proprio no.
  TAssert.AssertTrue(PipeTopicMatches('caixa.#', 'caixa'));
end;

procedure TPipeTopicsTests.Match_FiltroMaisLongoQueOTopico_NaoCasa;
begin
  TAssert.AssertFalse(PipeTopicMatches('caixa.3.status', 'caixa.3'));
  TAssert.AssertFalse(PipeTopicMatches('caixa.*', 'caixa'));
end;

procedure TPipeTopicsTests.Match_TopicoMaisLongoQueOFiltro_NaoCasa;
begin
  TAssert.AssertFalse(PipeTopicMatches('caixa.3', 'caixa.3.status'));
end;

procedure TPipeTopicsTests.Match_CuringasCombinados;
begin
  TAssert.AssertTrue(PipeTopicMatches('loja.*.caixa.#', 'loja.7.caixa.3.status'));
  TAssert.AssertTrue(PipeTopicMatches('loja.*.caixa.#', 'loja.7.caixa'));
  TAssert.AssertFalse(PipeTopicMatches('loja.*.caixa.#', 'loja.7.terminal.3'));
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
  TAssert.AssertEquals('caixa.3.status', LTopic);
  TAssert.AssertEquals(4, Length(LBody));
  TAssert.AssertEquals(10, LBody[0]);
  TAssert.AssertEquals(40, LBody[3]);
end;

procedure TPipeTopicsTests.Envelope_LayoutBinario;
var
  LBuf: TBytes;
begin
  // Layout no fio: u16 LE com o tamanho do topico, topico UTF-8, corpo.
  LBuf := PipeEncodeTopicPayload('ab', MakeBytes([99]));
  TAssert.AssertEquals(5, Length(LBuf));
  TAssert.AssertEquals(2, LBuf[0]);
  TAssert.AssertEquals(0, LBuf[1]);
  TAssert.AssertEquals(Ord('a'), LBuf[2]);
  TAssert.AssertEquals(Ord('b'), LBuf[3]);
  TAssert.AssertEquals(99, LBuf[4]);
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
  TAssert.AssertEquals('caixa.3', LTopic);
  TAssert.AssertEquals(0, Length(LBody));
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
  TAssert.AssertEquals(9, FPayload[0]); // 9 bytes, nao 7 caracteres
  TAssert.AssertEquals(0, FPayload[1]);
  PipeDecodeTopicPayload(FPayload, LTopic, LBody);
  LOut := PipeUtf8Encode(LTopic);
  TAssert.AssertEquals(Length(LIn), Length(LOut));
  for I := 0 to High(LIn) do
    TAssert.AssertEquals(LIn[I], LOut[I]);
  TAssert.AssertEquals(1, Length(LBody));
end;

procedure TPipeTopicsTests.Envelope_PayloadCurto_Levanta;
begin
  FPayload := MakeBytes([5]); // 1 byte: nem o u16 do tamanho cabe
  TAssert.AssertException(EPipeProtocol, DoDecodeTruncado);
end;

procedure TPipeTopicsTests.Envelope_TopicLenMaiorQuePayload_Levanta;
begin
  // Vem da rede: entrada hostil por definicao, e o decode nao pode ler alem.
  FPayload := MakeBytes([200, 0, Ord('a')]);
  TAssert.AssertException(EPipeProtocol, DoDecodeTruncado);
end;

{ --- frames --- }

procedure TPipeTopicsTests.Frame_Publish_KindEFlagDeRetain;
var
  LFrame: TPipeFrame;
  LTopic: string;
  LBody: TBytes;
begin
  LFrame := PipePublishFrame('caixa.3', MakeBytes([7]), False);
  TAssert.AssertTrue(LFrame.Kind = pfkPublish);
  TAssert.AssertFalse(LFrame.IsRetain);
  PipeDecodeTopicPayload(LFrame.Payload, LTopic, LBody);
  TAssert.AssertEquals('caixa.3', LTopic);
  TAssert.AssertEquals(7, LBody[0]);

  LFrame := PipePublishFrame('caixa.3', MakeBytes([7]), True);
  TAssert.AssertTrue(LFrame.IsRetain);
  TAssert.AssertFalse('retain e erro sao bits diferentes', LFrame.IsError);
end;

procedure TPipeTopicsTests.Frame_SubscribeEUnsubscribe;
var
  LFrame: TPipeFrame;
  LFilter: string;
  LBody: TBytes;
begin
  LFrame := PipeSubscribeFrame('caixa.#');
  TAssert.AssertTrue(LFrame.Kind = pfkSubscribe);
  PipeDecodeTopicPayload(LFrame.Payload, LFilter, LBody);
  TAssert.AssertEquals('caixa.#', LFilter);
  TAssert.AssertEquals(0, Length(LBody));

  LFrame := PipeUnsubscribeFrame('caixa.#');
  TAssert.AssertTrue(LFrame.Kind = pfkUnsubscribe);
  PipeDecodeTopicPayload(LFrame.Payload, LFilter, LBody);
  TAssert.AssertEquals('caixa.#', LFilter);
end;

initialization
  RegisterTest(TPipeTopicsTests);

end.
