unit Pipes.Commands;

{$I pipes.inc}

{ Roteador de comandos por nome, OPCIONAL e por CIMA de OnMessage: decora o
  evento existente do TPipeServer/TPipeClient com um dicionario nome->handler,
  trocando a cadeia de ifs que hoje separaria comandos dentro de um unico
  OnMessage por um RegisterCommand por comando.

  NAO muda o NPF1: nao ha kind novo, nao ha campo novo no header. O nome do
  comando viaja DENTRO do payload, no mesmo layout binario que Pipes.Topics
  usa para o nome do topico (u16 LE + UTF-8 + corpo) — layout repetido aqui
  de proposito, e nao importado de la: sao dois conceitos de dominio
  diferentes (assunto de uma publicacao vs. operacao pedida), so' a forma do
  envelope coincide.

  Como Pipes.Json, esta unit e' OPCIONAL: TPipeClient/TPipeServer nao a
  conhecem, so' o inverso. Quem nao precisar de comandos simplesmente nao
  inclui Pipes.Commands.pas no projeto.

  HandleMessage tem a MESMA assinatura de TPipeMessageEvent de proposito:
  atribua direto a Server.OnMessage/Client.OnMessage, sem wrapper.

  Validacao de payload (RegisterCommand com AMinSize/AMaxSize) roda ANTES do
  handler do comando — barato, e evita que cada handler reimplemente o mesmo
  "payload curto demais" na primeira linha. Envelope malformado e payload
  fora da faixa caem no MESMO OnInvalidPayload (ACommand vem vazio no
  primeiro caso, que e' anterior a qualquer lookup); comando sem handler
  registrado cai em OnUnknownCommand. Os dois sao opcionais e silenciosos
  por padrao (mesmo comportamento de um OnMessage sem assinante) — e nao por
  acaso: uma excecao levantada dentro de HandleMessage seria engolida em
  silencio pelo pool de qualquer jeito (TPipePoolWorker.Execute, em
  Pipes.Threading, nao tem para onde relatar excecao de callback de
  usuario), entao um evento proprio, e nao raise, e' o unico jeito do dev
  enxergar o descarte.

  Registro (RegisterCommand) e' o oposto: nome invalido, handler nil,
  limites inconsistentes ou comando duplicado sao erro de PROGRAMACAO, nao
  de rede — por isso levantam EPipeCommandError na hora do registro, nao no
  primeiro frame que chegar.

  RegisterRequestCommand/HandleRequest fazem o mesmo roteamento do lado
  request-reply (TPipeServer.OnRequest/TPipeRequestEvent) — registro proprio
  (RegisterRequestCommand), dicionario proprio (nome de comando de mensagem e
  de request NAO colidem: chegam por kinds diferentes no fio, pfkMessage vs
  pfkRequest/pfkReply, antes de qualquer lookup). O contrato de erro e' o
  OPOSTO do de HandleMessage, de proposito: HandleRequest LEVANTA em comando
  desconhecido ou payload fora da faixa (nao ha OnUnknownCommand/
  OnInvalidPayload do lado do request), porque TPipeServer.ExecuteRequest ja'
  captura QUALQUER excecao de dentro de OnRequest e a transforma em reply de
  erro pro cliente (Pipes.Server.pas, mesmo caminho que EchoJsonServer ja usa
  de proposito com EPipeJSONError) — reaproveitar esse mecanismo e' mais
  simples do que reinventar um "silencio" que nao existe no request-reply
  (o worker sempre manda ALGUMA resposta, nunca nada). O reply em si nao leva
  envelope: quem chamou Request ja sabe qual comando mandou, entao AReply
  continua TBytes cru.

  PipeSendCommand/PipeSendCommandText/PipeRequestCommand/
  PipeRequestCommandText sao wrappers finos sobre SendBytes/Request que so'
  poupam o PipeEncodeCommandPayload repetido em quem manda comando toda hora
  — mesma ideia de PipeSendJSON/PipeRequestJSON em Pipes.Json.pas, ate' a
  mesma dupla de overloads (Client / Server+AConnId) para o lado
  fire-and-forget. Nao mudam nada em TPipeClient/TPipeServer: esta unit
  depende deles, nunca o contrario. Ver docs/ARQUITETURA.md §18.9. }

interface

uses
  SysUtils,
  Generics.Collections,
  Pipes.Types,
  Pipes.Framing,
  Pipes.Client,
  Pipes.Server;

const
  /// Desliga o respectivo teto de tamanho em RegisterCommand.
  PIPE_COMMAND_NO_LIMIT = -1;
  /// Teto do NOME do comando em bytes UTF-8 — mesmo raciocinio de
  /// PIPE_MAX_TOPIC_BYTES (Pipes.Topics): o nome nao pode virar payload
  /// disfarcado.
  PIPE_MAX_COMMAND_BYTES = 255;

type
  /// Handler de um comando. APayload ja' vem SEM o prefixo do envelope, so'
  /// o corpo.
  TPipeCommandEvent = procedure(Sender: TObject; AConnId: TPipeConnectionId;
    const ACommand: string; const APayload: TBytes) of object;

  /// Handler de um comando do lado request-reply. Mesma ideia de
  /// TPipeCommandEvent, mas com a assinatura de TPipeRequestEvent: o retorno
  /// em AReply vira o frame de resposta (RAW, sem envelope — quem chamou
  /// Request ja sabe qual comando mandou).
  TPipeCommandRequestEvent = procedure(Sender: TObject; AConnId: TPipeConnectionId;
    const ACommand: string; const APayload: TBytes; out AReply: TBytes) of object;

  /// Erro de PROGRAMACAO em RegisterCommand (nome invalido, handler nil,
  /// limites inconsistentes, comando duplicado) — nunca levantada a partir
  /// de um frame recebido.
  EPipeCommandError = class(EPipeError);

  /// Um comando registrado: handler + faixa de tamanho aceita para o corpo
  /// (PIPE_COMMAND_NO_LIMIT desliga o respectivo lado).
  TPipeCommandEntry = record
    Handler: TPipeCommandEvent;
    MinSize: Integer;
    MaxSize: Integer;
  end;

  /// Idem TPipeCommandEntry, para o registro do lado request-reply.
  TPipeCommandRequestEntry = record
    Handler: TPipeCommandRequestEvent;
    MinSize: Integer;
    MaxSize: Integer;
  end;

  TPipeCommandRouter = class
  private
    FCommands: TDictionary<string, TPipeCommandEntry>;
    FRequestCommands: TDictionary<string, TPipeCommandRequestEntry>;
    FOnUnknownCommand: TPipeCommandEvent;
    FOnInvalidPayload: TPipeCommandEvent;
    procedure ValidateRegistration(const ACommand: string;
      AHandlerAssigned, AAlreadyRegistered: Boolean;
      AMinSize, AMaxSize: Integer);
  public
    constructor Create;
    destructor Destroy; override;

    /// Registra o handler de ACommand (lado OnMessage). Levanta
    /// EPipeCommandError se: o nome for vazio ou passar de
    /// PIPE_MAX_COMMAND_BYTES; AHandler nao estiver atribuido; AMinSize/
    /// AMaxSize forem negativos fora de PIPE_COMMAND_NO_LIMIT, ou
    /// AMaxSize < AMinSize; ou ACommand ja' estiver registrado NESTE
    /// registro (o registro de request, abaixo, e' independente — o mesmo
    /// nome pode existir nos dois sem conflito).
    procedure RegisterCommand(const ACommand: string;
      AHandler: TPipeCommandEvent;
      AMinSize: Integer = PIPE_COMMAND_NO_LIMIT;
      AMaxSize: Integer = PIPE_COMMAND_NO_LIMIT);

    /// Registra o handler de ACommand do lado request-reply (TPipeServer.
    /// OnRequest). Mesmas validacoes/EPipeCommandError de RegisterCommand,
    /// contra um registro PROPRIO (ver HandleRequest).
    procedure RegisterRequestCommand(const ACommand: string;
      AHandler: TPipeCommandRequestEvent;
      AMinSize: Integer = PIPE_COMMAND_NO_LIMIT;
      AMaxSize: Integer = PIPE_COMMAND_NO_LIMIT);

    /// Compativel com TPipeMessageEvent — atribua direto a
    /// Server.OnMessage/Client.OnMessage (ver cabecalho da unit).
    procedure HandleMessage(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);

    /// Compativel com TPipeRequestEvent — atribua direto a
    /// Server.OnRequest (ver cabecalho da unit). AO CONTRARIO de
    /// HandleMessage, LEVANTA (EPipeProtocol) em envelope malformado,
    /// comando sem handler registrado ou payload fora da faixa MinSize/
    /// MaxSize: TPipeServer.ExecuteRequest ja' transforma qualquer excecao
    /// vinda daqui em reply de erro para o cliente, entao nao ha
    /// OnUnknownCommand/OnInvalidPayload deste lado.
    procedure HandleRequest(Sender: TObject; AConnId: TPipeConnectionId;
      const ARequest: TBytes; out AReply: TBytes);

    /// Envelope decodificou mas nao ha handler para o comando. Opcional; sem
    /// assinante a mensagem e' descartada em silencio. So' se aplica a
    /// HandleMessage — HandleRequest sempre levanta (ver acima).
    property OnUnknownCommand: TPipeCommandEvent
      read FOnUnknownCommand write FOnUnknownCommand;
    /// Envelope malformado (ACommand vem vazio) OU payload fora da faixa
    /// MinSize/MaxSize do comando. Opcional, mesmo silencio de
    /// OnUnknownCommand quando nao atribuido. So' se aplica a HandleMessage.
    property OnInvalidPayload: TPipeCommandEvent
      read FOnInvalidPayload write FOnInvalidPayload;
  end;

/// Monta o envelope (nome do comando + corpo) que vai no payload do frame.
function PipeEncodeCommandPayload(const ACommand: string;
  const ABody: TBytes): TBytes;
/// Desmonta o envelope. EPipeProtocol se o payload nao contem o envelope
/// inteiro — pode vir da rede, e' entrada hostil por definicao.
procedure PipeDecodeCommandPayload(const APayload: TBytes; out ACommand: string;
  out ABody: TBytes);

{ Wrappers finos sobre SendBytes/SendText/Request — so' poupam o
  PipeEncodeCommandPayload repetido em quem manda/pede comando toda hora (ver
  cabecalho da unit e docs/ARQUITETURA.md §18.9). }

procedure PipeSendCommand(AClient: TPipeClient; const ACommand: string;
  const ABody: TBytes; const AGroupKey: string = ''); overload;
procedure PipeSendCommand(AServer: TPipeServer; AConnId: TPipeConnectionId;
  const ACommand: string; const ABody: TBytes;
  const AGroupKey: string = ''); overload;

procedure PipeSendCommandText(AClient: TPipeClient; const ACommand: string;
  const ABody: string; const AGroupKey: string = ''); overload;
procedure PipeSendCommandText(AServer: TPipeServer; AConnId: TPipeConnectionId;
  const ACommand: string; const ABody: string;
  const AGroupKey: string = ''); overload;

/// Como Request, mas monta o envelope de comando antes de mandar. AReply
/// devolvido e' RAW (sem envelope) — quem chamou ja sabe o que pediu, mesmo
/// contrato de TPipeCommandRequestEvent (ver HandleRequest). Mesmas
/// excecoes de Request (EPipeTimeout/EPipeClosed/EPipeError), mais
/// EPipeProtocol se ACommand exceder PIPE_MAX_COMMAND_BYTES.
function PipeRequestCommand(AClient: TPipeClient; const ACommand: string;
  const ABody: TBytes; ATimeoutMs: Cardinal = 30000): TBytes;

/// Como PipeRequestCommand, com corpo e resposta em texto (UTF-8) — mesmo
/// padrao de TPipeClient.RequestText.
function PipeRequestCommandText(AClient: TPipeClient; const ACommand: string;
  const ABody: string; ATimeoutMs: Cardinal = 30000): string;

implementation

{ --- envelope --- }

function PipeEncodeCommandPayload(const ACommand: string;
  const ABody: TBytes): TBytes;
var
  LCommand: TBytes;
  LLen: Integer;
begin
  LCommand := PipeUtf8Encode(ACommand);
  LLen := Length(LCommand);
  if LLen > PIPE_MAX_COMMAND_BYTES then
    raise EPipeProtocol.CreateFmt(
      'nome de comando de %d bytes excede o maximo (%d)',
      [LLen, PIPE_MAX_COMMAND_BYTES]);
  Result := nil;
  SetLength(Result, 2 + LLen + Length(ABody));
  Result[0] := Byte(LLen);
  Result[1] := Byte(LLen shr 8);
  if LLen > 0 then
    Move(LCommand[0], Result[2], LLen);
  if Length(ABody) > 0 then
    Move(ABody[0], Result[2 + LLen], Length(ABody));
end;

procedure PipeDecodeCommandPayload(const APayload: TBytes; out ACommand: string;
  out ABody: TBytes);
var
  LLen, LBody: Integer;
  LCommand: TBytes;
begin
  ACommand := '';
  ABody := nil;
  if Length(APayload) < 2 then
    raise EPipeProtocol.Create('frame de comando sem o cabecalho do envelope');
  LLen := APayload[0] or (Integer(APayload[1]) shl 8);
  if Length(APayload) < 2 + LLen then
    raise EPipeProtocol.CreateFmt(
      'envelope anuncia comando de %d bytes mas o payload tem %d',
      [LLen, Length(APayload) - 2]);
  SetLength(LCommand, LLen);
  if LLen > 0 then
    Move(APayload[2], LCommand[0], LLen);
  ACommand := PipeUtf8Decode(LCommand);
  LBody := Length(APayload) - 2 - LLen;
  SetLength(ABody, LBody);
  if LBody > 0 then
    Move(APayload[2 + LLen], ABody[0], LBody);
end;

{ TPipeCommandRouter }

constructor TPipeCommandRouter.Create;
begin
  inherited Create;
  FCommands := TDictionary<string, TPipeCommandEntry>.Create;
  FRequestCommands := TDictionary<string, TPipeCommandRequestEntry>.Create;
end;

destructor TPipeCommandRouter.Destroy;
begin
  FCommands.Free;
  FRequestCommands.Free;
  inherited Destroy;
end;

// Validacoes comuns a RegisterCommand/RegisterRequestCommand — o que muda
// entre os dois (tipo do handler, qual dicionario) fica com o chamador, que
// ja sabe se o handler esta atribuido e se o nome ja existe NO SEU PROPRIO
// registro (os dois registros sao independentes, ver cabecalho da unit).
procedure TPipeCommandRouter.ValidateRegistration(const ACommand: string;
  AHandlerAssigned, AAlreadyRegistered: Boolean; AMinSize, AMaxSize: Integer);
begin
  if ACommand = '' then
    raise EPipeCommandError.Create('nome de comando vazio');
  if Length(PipeUtf8Encode(ACommand)) > PIPE_MAX_COMMAND_BYTES then
    raise EPipeCommandError.CreateFmt(
      'nome de comando "%s" excede o maximo de %d bytes',
      [ACommand, PIPE_MAX_COMMAND_BYTES]);
  if not AHandlerAssigned then
    raise EPipeCommandError.CreateFmt(
      'comando "%s" registrado sem handler', [ACommand]);
  if (AMinSize <> PIPE_COMMAND_NO_LIMIT) and (AMinSize < 0) then
    raise EPipeCommandError.CreateFmt(
      'AMinSize invalido (%d) para o comando "%s"', [AMinSize, ACommand]);
  if (AMaxSize <> PIPE_COMMAND_NO_LIMIT) and (AMaxSize < 0) then
    raise EPipeCommandError.CreateFmt(
      'AMaxSize invalido (%d) para o comando "%s"', [AMaxSize, ACommand]);
  if (AMinSize <> PIPE_COMMAND_NO_LIMIT) and (AMaxSize <> PIPE_COMMAND_NO_LIMIT)
     and (AMaxSize < AMinSize) then
    raise EPipeCommandError.CreateFmt(
      'AMaxSize (%d) menor que AMinSize (%d) para o comando "%s"',
      [AMaxSize, AMinSize, ACommand]);
  if AAlreadyRegistered then
    raise EPipeCommandError.CreateFmt('comando "%s" ja registrado', [ACommand]);
end;

procedure TPipeCommandRouter.RegisterCommand(const ACommand: string;
  AHandler: TPipeCommandEvent; AMinSize, AMaxSize: Integer);
var
  LEntry: TPipeCommandEntry;
begin
  ValidateRegistration(ACommand, Assigned(AHandler),
    FCommands.ContainsKey(ACommand), AMinSize, AMaxSize);
  LEntry.Handler := AHandler;
  LEntry.MinSize := AMinSize;
  LEntry.MaxSize := AMaxSize;
  FCommands.Add(ACommand, LEntry);
end;

procedure TPipeCommandRouter.RegisterRequestCommand(const ACommand: string;
  AHandler: TPipeCommandRequestEvent; AMinSize, AMaxSize: Integer);
var
  LEntry: TPipeCommandRequestEntry;
begin
  ValidateRegistration(ACommand, Assigned(AHandler),
    FRequestCommands.ContainsKey(ACommand), AMinSize, AMaxSize);
  LEntry.Handler := AHandler;
  LEntry.MinSize := AMinSize;
  LEntry.MaxSize := AMaxSize;
  FRequestCommands.Add(ACommand, LEntry);
end;

procedure TPipeCommandRouter.HandleMessage(Sender: TObject;
  AConnId: TPipeConnectionId; const AData: TBytes);
var
  LCommand: string;
  LBody: TBytes;
  LEntry: TPipeCommandEntry;
begin
  try
    PipeDecodeCommandPayload(AData, LCommand, LBody);
  except
    on E: EPipeProtocol do
    begin
      if Assigned(FOnInvalidPayload) then
        FOnInvalidPayload(Sender, AConnId, '', AData);
      Exit;
    end;
  end;

  if not FCommands.TryGetValue(LCommand, LEntry) then
  begin
    if Assigned(FOnUnknownCommand) then
      FOnUnknownCommand(Sender, AConnId, LCommand, LBody);
    Exit;
  end;

  if ((LEntry.MinSize <> PIPE_COMMAND_NO_LIMIT) and
      (Length(LBody) < LEntry.MinSize)) or
     ((LEntry.MaxSize <> PIPE_COMMAND_NO_LIMIT) and
      (Length(LBody) > LEntry.MaxSize)) then
  begin
    if Assigned(FOnInvalidPayload) then
      FOnInvalidPayload(Sender, AConnId, LCommand, LBody);
    Exit;
  end;

  LEntry.Handler(Sender, AConnId, LCommand, LBody);
end;

procedure TPipeCommandRouter.HandleRequest(Sender: TObject;
  AConnId: TPipeConnectionId; const ARequest: TBytes; out AReply: TBytes);
var
  LCommand: string;
  LBody: TBytes;
  LEntry: TPipeCommandRequestEntry;
begin
  // Envelope malformado propaga como esta: EPipeProtocol de
  // PipeDecodeCommandPayload ja tem a mensagem certa, e ExecuteRequest vai
  // capturar do mesmo jeito que qualquer excecao daqui pra baixo.
  PipeDecodeCommandPayload(ARequest, LCommand, LBody);

  if not FRequestCommands.TryGetValue(LCommand, LEntry) then
    raise EPipeProtocol.CreateFmt('comando desconhecido: "%s"', [LCommand]);

  if ((LEntry.MinSize <> PIPE_COMMAND_NO_LIMIT) and
      (Length(LBody) < LEntry.MinSize)) or
     ((LEntry.MaxSize <> PIPE_COMMAND_NO_LIMIT) and
      (Length(LBody) > LEntry.MaxSize)) then
    raise EPipeProtocol.CreateFmt(
      'payload de %d byte(s) fora da faixa aceita pelo comando "%s"',
      [Length(LBody), LCommand]);

  LEntry.Handler(Sender, AConnId, LCommand, LBody, AReply);
end;

{ --- wrappers de conveniencia --- }

procedure PipeSendCommand(AClient: TPipeClient; const ACommand: string;
  const ABody: TBytes; const AGroupKey: string); overload;
begin
  AClient.SendBytes(PipeEncodeCommandPayload(ACommand, ABody), AGroupKey);
end;

procedure PipeSendCommand(AServer: TPipeServer; AConnId: TPipeConnectionId;
  const ACommand: string; const ABody: TBytes; const AGroupKey: string); overload;
begin
  AServer.SendBytes(AConnId, PipeEncodeCommandPayload(ACommand, ABody), AGroupKey);
end;

procedure PipeSendCommandText(AClient: TPipeClient; const ACommand: string;
  const ABody: string; const AGroupKey: string); overload;
begin
  PipeSendCommand(AClient, ACommand, PipeUtf8Encode(ABody), AGroupKey);
end;

procedure PipeSendCommandText(AServer: TPipeServer; AConnId: TPipeConnectionId;
  const ACommand: string; const ABody: string; const AGroupKey: string); overload;
begin
  PipeSendCommand(AServer, AConnId, ACommand, PipeUtf8Encode(ABody), AGroupKey);
end;

function PipeRequestCommand(AClient: TPipeClient; const ACommand: string;
  const ABody: TBytes; ATimeoutMs: Cardinal): TBytes;
begin
  Result := AClient.Request(PipeEncodeCommandPayload(ACommand, ABody), ATimeoutMs);
end;

function PipeRequestCommandText(AClient: TPipeClient; const ACommand: string;
  const ABody: string; ATimeoutMs: Cardinal): string;
begin
  Result := PipeUtf8Decode(
    PipeRequestCommand(AClient, ACommand, PipeUtf8Encode(ABody), ATimeoutMs));
end;

end.
