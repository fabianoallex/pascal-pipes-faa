unit Pipes.Json;

{$I pipes.inc}

{ Helper OPCIONAL de fronteira entre TBytes (wire) e JSON. NAO faz parte do
  core: Pipes.Client/Pipes.Server nao conhecem esta unit, so' o inverso. Quem
  nao precisar de JSON simplesmente nao inclui Pipes.Json.pas no projeto, e
  nao paga o custo de linkar System.JSON (Delphi) nem fpjson (FPC).

  So' a FRONTEIRA bytes<->valor e' unificada aqui (PipeBytesToJSON/
  PipeJSONToBytes), atraves do alias TPipeJSONValue. Construir ou ler o valor
  (AddPair vs Add, GetValue vs FindPath) continua sendo a API nativa de cada
  lib — unificar isso tambem estufaria a unit sem necessidade real, e quem
  tiver um caso especifico (outra lib JSON, outro formato) implementa por
  conta propria em cima de SendBytes/TBytes, sem nenhuma penalidade.

  Dono do valor: igual as duas libs nativas, quem recebe um TPipeJSONValue
  (de PipeBytesToJSON ou PipeRequestJSON) da' Free nele; PipeJSONToBytes e
  PipeSendJSON nunca liberam o que recebem. }

interface

uses
  SysUtils,
  {$IFDEF FPC}
  fpjson, jsonparser,
  {$ELSE}
  System.JSON,
  {$ENDIF}
  Pipes.Types, Pipes.Framing, Pipes.Client, Pipes.Server;

type
  {$IFDEF FPC}
  TPipeJSONValue = TJSONData;
  {$ELSE}
  TPipeJSONValue = TJSONValue;
  {$ENDIF}

  /// JSON invalido ou vazio no parse (payload recebido ou resposta de Request).
  EPipeJSONError = class(EPipeError);

/// Faz o parse do payload (UTF-8) recebido em OnMessage/OnRequest/Request
/// como JSON. O chamador e' dono do valor devolvido (Free depois de usar).
/// Levanta EPipeJSONError se o payload nao for JSON valido.
function PipeBytesToJSON(const AData: TBytes): TPipeJSONValue;

/// Serializa AValue para TBytes (UTF-8), pronto para SendBytes/Request. Nao
/// libera AValue - o chamador continua dono.
function PipeJSONToBytes(AValue: TPipeJSONValue): TBytes;

{ Wrappers finos sobre SendBytes/Request, so' pra poupar o
  PipeJSONToBytes/PipeBytesToJSON repetido em quem manda/pede JSON toda hora.
  Nao mudam nada em TPipeClient/TPipeServer - esta unit depende deles, nunca
  o contrario. }

procedure PipeSendJSON(AClient: TPipeClient; AValue: TPipeJSONValue); overload;
procedure PipeSendJSON(AServer: TPipeServer; AConnId: TPipeConnectionId;
  AValue: TPipeJSONValue); overload;

/// Como Request, mas devolve TPipeJSONValue ja' parseado (chamador libera).
/// Mesmas excecoes de Request (EPipeTimeout/EPipeClosed/EPipeError), mais
/// EPipeJSONError se a resposta nao for JSON valido.
function PipeRequestJSON(AClient: TPipeClient; AValue: TPipeJSONValue;
  ATimeoutMs: Cardinal = 30000): TPipeJSONValue;

implementation

function PipeBytesToJSON(const AData: TBytes): TPipeJSONValue;
var
  LText: string;
begin
  LText := PipeUtf8Decode(AData);
  // Payload vazio: GetJSON('') e ParseJSONValue('') nao concordam entre si
  // (nem sempre levantam/devolvem nil de forma confiavel) - checado aqui na
  // fronteira em vez de depender do comportamento de cada lib nesse caso.
  if LText = '' then
    raise EPipeJSONError.Create('JSON vazio');
  {$IFDEF FPC}
  // GetJSON (jsonparser) levanta em texto invalido; normalizamos para
  // EPipeJSONError em vez de deixar a excecao nativa (EJSONParser/
  // EScannerError) vazar para quem chama - o Delphi nao tem essa mesma classe.
  try
    Result := GetJSON(LText);
  except
    on E: Exception do
      raise EPipeJSONError.CreateFmt('JSON invalido: %s', [E.Message]);
  end;
  {$ELSE}
  // ParseJSONValue (System.JSON) devolve nil em vez de levantar - mesma
  // normalizacao, no sentido oposto.
  Result := TJSONObject.ParseJSONValue(LText);
  if Result = nil then
    raise EPipeJSONError.Create('JSON invalido');
  {$ENDIF}
end;

function PipeJSONToBytes(AValue: TPipeJSONValue): TBytes;
begin
  {$IFDEF FPC}
  Result := PipeUtf8Encode(AValue.AsJSON);
  {$ELSE}
  Result := PipeUtf8Encode(AValue.ToJSON);
  {$ENDIF}
end;

procedure PipeSendJSON(AClient: TPipeClient; AValue: TPipeJSONValue); overload;
begin
  AClient.SendBytes(PipeJSONToBytes(AValue));
end;

procedure PipeSendJSON(AServer: TPipeServer; AConnId: TPipeConnectionId;
  AValue: TPipeJSONValue); overload;
begin
  AServer.SendBytes(AConnId, PipeJSONToBytes(AValue));
end;

function PipeRequestJSON(AClient: TPipeClient; AValue: TPipeJSONValue;
  ATimeoutMs: Cardinal): TPipeJSONValue;
begin
  Result := PipeBytesToJSON(AClient.Request(PipeJSONToBytes(AValue), ATimeoutMs));
end;

end.
