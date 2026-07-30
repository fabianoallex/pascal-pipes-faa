unit Pipes.Topics;

{$I pipes.inc}

{ Nomes de topico, casamento hierarquico e envelope das mensagens de pub/sub.

  Esta unit e' PURA: sem estado, sem locks, sem IO. Todo o roteamento do
  pub/sub sai daqui, e e' de proposito que ele caiba num punhado de funcoes
  testaveis sem abrir uma conexao — a camada de cima decide QUEM recebe usando
  PipeTopicMatches, e essa decisao roda na thread de leitura (ver o cabecalho
  de Pipes.Server), onde nada que possa bloquear e' permitido.

  --- Nomes -----------------------------------------------------------------

  Topico e' hierarquico, separado por ponto: 'caixa.3.status'. Segmento vazio
  e' invalido, ou seja, nao ha ponto no inicio, no fim, nem dois seguidos.
  Comparacao byte a byte: 'Caixa' e 'caixa' sao topicos DIFERENTES (nao ha
  upcase portatil para UTF-8, e um casamento que depende de locale seria pior
  que um sensivel a caixa).

  Quem PUBLICA usa nome literal; quem ASSINA usa um filtro, que aceita dois
  curingas, sempre ocupando um segmento inteiro:

    *  exatamente um segmento     'caixa.*.status' casa 'caixa.3.status'
                                  e NAO casa 'caixa.3.a.status'
    #  o resto, inclusive nada    'caixa.#' casa 'caixa.3.status' e 'caixa'

  '#' so' pode ser o ULTIMO segmento — 'a.#.b' e' invalido. E' recusado em vez
  de interpretado porque as duas leituras possiveis ("#" como um segmento ou
  como varios) dariam resultados diferentes para o mesmo filtro.

  --- Envelope --------------------------------------------------------------

  O topico viaja DENTRO do payload do frame NPF1, nao no header:

    offset 0  TopicLen  2 bytes  tamanho do topico em bytes UTF-8 (LE)
    offset 2  Topic     TopicLen bytes UTF-8
    offset 2+TopicLen   corpo (TBytes cru)

  Os 2 bytes Reserved do header (Pipes.Framing) serviriam, e seriam mais
  baratos — mas o campo Length deixaria de cobrir o resto do frame, e um peer
  de versao anterior leria a quantidade errada de bytes e sairia de sincronia,
  passando a acusar 'magic invalido' em frames perfeitos. Com o topico dentro
  do payload, esse peer falha limpo no proprio kind desconhecido, e o stream
  nunca fica dessincronizado. }

interface

uses
  SysUtils,
  Pipes.Types,
  Pipes.Framing;

const
  PIPE_TOPIC_SEPARATOR = '.';
  PIPE_TOPIC_WILDCARD_ONE = '*';
  PIPE_TOPIC_WILDCARD_REST = '#';
  /// Teto do nome em bytes UTF-8. Cabe em 2 bytes com folga de sobra; o limite
  /// existe para que um filtro nao possa ser usado como payload disfarcado
  /// (a lista de assinaturas do servidor e' memoria que o CLIENTE dita).
  PIPE_MAX_TOPIC_BYTES = 255;

/// Nome literal, para publicar: hierarquico, sem curinga, sem segmento vazio,
/// sem caractere de controle, ate PIPE_MAX_TOPIC_BYTES.
function PipeIsValidTopic(const ATopic: string): Boolean;
/// Filtro, para assinar: as regras de PipeIsValidTopic mais os curingas '*'
/// (um segmento) e '#' (o resto, so' no ultimo segmento).
function PipeIsValidTopicFilter(const AFilter: string): Boolean;

/// True se o filtro de assinatura alcanca o topico publicado. Assume os dois
/// ja validados; com entrada invalida o resultado nao tem significado (e' a
/// camada de cima que recusa antes, uma vez, em vez de revalidar por mensagem
/// no caminho quente do fanout).
function PipeTopicMatches(const AFilter, ATopic: string): Boolean;

/// Monta o envelope (topico + corpo) que vai no payload do frame.
function PipeEncodeTopicPayload(const ATopic: string;
  const ABody: TBytes): TBytes;
/// Desmonta o envelope. EPipeProtocol se o payload nao contem o envelope
/// inteiro — vem da rede, entao e' entrada hostil por definicao.
procedure PipeDecodeTopicPayload(const APayload: TBytes; out ATopic: string;
  out ABody: TBytes);

/// Frames de pub/sub prontos. ARetain marca PIPE_FLAG_RETAIN no frame de
/// publicacao (corpo vazio + retain = apagar o valor retido do topico).
function PipePublishFrame(const ATopic: string; const ABody: TBytes;
  ARetain: Boolean): TPipeFrame;
function PipeSubscribeFrame(const AFilter: string): TPipeFrame;
function PipeUnsubscribeFrame(const AFilter: string): TPipeFrame;

implementation

{ --- segmentacao ------------------------------------------------------------

  Caminhada por indice, sem alocar lista de segmentos: PipeTopicMatches roda
  uma vez por conexao por mensagem publicada, sob o lock da lista de conexoes
  (ver Pipes.Server). Uma alocacao por segmento ali seria a diferenca entre
  microssegundos e milissegundos com algumas centenas de clientes. }

// Proximo segmento a partir de APos (1-based); False quando acabou.
function NextSeg(const S: string; var APos: Integer; out ASeg: string): Boolean;
var
  LEnd: Integer;
begin
  ASeg := '';
  Result := APos <= Length(S);
  if not Result then
    Exit;
  LEnd := APos;
  while (LEnd <= Length(S)) and (S[LEnd] <> PIPE_TOPIC_SEPARATOR) do
    Inc(LEnd);
  ASeg := Copy(S, APos, LEnd - APos);
  APos := LEnd + 1; // pula o separador
end;

// Regras comuns a nome e filtro. AAllowWildcards libera '*' e '#'.
function IsValidName(const AValue: string; AAllowWildcards: Boolean): Boolean;
var
  LPos, I: Integer;
  LSeg: string;
  LSawRest: Boolean;
begin
  Result := False;
  if AValue = '' then
    Exit;
  if Length(PipeUtf8Encode(AValue)) > PIPE_MAX_TOPIC_BYTES then
    Exit;
  // Ponto no inicio ou no fim produziria segmento vazio que NextSeg nao
  // enxerga (ele para no fim da string), entao os dois casos vao aqui.
  if (AValue[1] = PIPE_TOPIC_SEPARATOR) or
     (AValue[Length(AValue)] = PIPE_TOPIC_SEPARATOR) then
    Exit;
  LPos := 1;
  LSawRest := False;
  while NextSeg(AValue, LPos, LSeg) do
  begin
    if LSawRest then
      Exit; // '#' tinha de ser o ultimo
    if LSeg = '' then
      Exit; // '..'
    for I := 1 to Length(LSeg) do
    begin
      if LSeg[I] < ' ' then
        Exit; // controle: nao ha topico legitimo com isso, e suja log
      if (LSeg[I] = PIPE_TOPIC_WILDCARD_ONE) or
         (LSeg[I] = PIPE_TOPIC_WILDCARD_REST) then
        // Curinga so' vale como segmento INTEIRO: 'caixa*' seria uma promessa
        // de casamento parcial que este matcher nao cumpre.
        if (not AAllowWildcards) or (Length(LSeg) <> 1) then
          Exit;
    end;
    if LSeg = PIPE_TOPIC_WILDCARD_REST then
      LSawRest := True;
  end;
  Result := True;
end;

function PipeIsValidTopic(const ATopic: string): Boolean;
begin
  Result := IsValidName(ATopic, False);
end;

function PipeIsValidTopicFilter(const AFilter: string): Boolean;
begin
  Result := IsValidName(AFilter, True);
end;

function PipeTopicMatches(const AFilter, ATopic: string): Boolean;
var
  LFPos, LTPos: Integer;
  LFSeg, LTSeg: string;
  LHasF, LHasT: Boolean;
begin
  LFPos := 1;
  LTPos := 1;
  while True do
  begin
    LHasF := NextSeg(AFilter, LFPos, LFSeg);
    // '#' antes de consumir o segmento do topico: e' o que faz 'caixa.#'
    // alcancar 'caixa' (o resto pode ser vazio).
    if LHasF and (LFSeg = PIPE_TOPIC_WILDCARD_REST) then
      Exit(True);
    LHasT := NextSeg(ATopic, LTPos, LTSeg);
    if (not LHasF) or (not LHasT) then
      Exit(LHasF = LHasT); // casam so' se acabaram juntos
    if (LFSeg <> PIPE_TOPIC_WILDCARD_ONE) and (LFSeg <> LTSeg) then
      Exit(False);
  end;
end;

{ --- envelope --- }

function PipeEncodeTopicPayload(const ATopic: string;
  const ABody: TBytes): TBytes;
var
  LTopic: TBytes;
  LLen: Integer;
begin
  LTopic := PipeUtf8Encode(ATopic);
  LLen := Length(LTopic);
  if LLen > PIPE_MAX_TOPIC_BYTES then
    raise EPipeProtocol.CreateFmt('topico de %d bytes excede o maximo (%d)',
      [LLen, PIPE_MAX_TOPIC_BYTES]);
  Result := nil;
  SetLength(Result, 2 + LLen + Length(ABody));
  Result[0] := Byte(LLen);
  Result[1] := Byte(LLen shr 8);
  if LLen > 0 then
    Move(LTopic[0], Result[2], LLen);
  if Length(ABody) > 0 then
    Move(ABody[0], Result[2 + LLen], Length(ABody));
end;

procedure PipeDecodeTopicPayload(const APayload: TBytes; out ATopic: string;
  out ABody: TBytes);
var
  LLen, LBody: Integer;
  LTopic: TBytes;
begin
  ATopic := '';
  ABody := nil;
  if Length(APayload) < 2 then
    raise EPipeProtocol.Create('frame de topico sem o cabecalho do envelope');
  LLen := APayload[0] or (Integer(APayload[1]) shl 8);
  if Length(APayload) < 2 + LLen then
    raise EPipeProtocol.CreateFmt(
      'envelope anuncia topico de %d bytes mas o payload tem %d',
      [LLen, Length(APayload) - 2]);
  SetLength(LTopic, LLen);
  if LLen > 0 then
    Move(APayload[2], LTopic[0], LLen);
  ATopic := PipeUtf8Decode(LTopic);
  LBody := Length(APayload) - 2 - LLen;
  SetLength(ABody, LBody);
  if LBody > 0 then
    Move(APayload[2 + LLen], ABody[0], LBody);
end;

{ --- frames --- }

function PipePublishFrame(const ATopic: string; const ABody: TBytes;
  ARetain: Boolean): TPipeFrame;
begin
  Result.Kind := pfkPublish;
  if ARetain then
    Result.Flags := PIPE_FLAG_RETAIN
  else
    Result.Flags := 0;
  Result.CorrId := 0;
  Result.Payload := PipeEncodeTopicPayload(ATopic, ABody);
end;

function PipeSubscribeFrame(const AFilter: string): TPipeFrame;
begin
  Result.Kind := pfkSubscribe;
  Result.Flags := 0;
  Result.CorrId := 0;
  Result.Payload := PipeEncodeTopicPayload(AFilter, nil);
end;

function PipeUnsubscribeFrame(const AFilter: string): TPipeFrame;
begin
  Result.Kind := pfkUnsubscribe;
  Result.Flags := 0;
  Result.CorrId := 0;
  Result.Payload := PipeEncodeTopicPayload(AFilter, nil);
end;

end.
