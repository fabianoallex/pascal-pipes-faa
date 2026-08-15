program EchoCommandServer;

{ Servidor de eco console com roteamento por COMANDO, usando
  Pipes.Commands.pas (helper OPCIONAL, ver README.md secao "Comandos") em vez
  de um unico OnMessage/OnRequest com cadeia de if/case: cada comando ganha
  seu proprio handler via TPipeCommandRouter.RegisterCommand/
  RegisterRequestCommand.

  Comandos fire-and-forget (via SendBytes do cliente, chegam em OnMessage):
    PING           -> servidor responde com o comando PONG (corpo vazio)
    ECO <texto>    -> servidor responde com ECO_OK e o texto em maiusculas

  Comando request-reply (via Request do cliente, chega em OnRequest):
    SOMAR <a> <b>  -> servidor responde com a soma dos dois inteiros

  Comando desconhecido/payload fora da faixa se comportam DIFERENTE conforme
  o lado: no lado OnMessage caem em OnUnknownCommand/OnInvalidPayload (so'
  logam, mesmo silencio de um OnMessage sem assinante — nao ha pra quem
  responder); no lado OnRequest, HandleRequest LEVANTA, e o proprio
  TPipeServer.ExecuteRequest transforma isso num reply de erro que o
  Request do cliente relanca como EPipeError (ver EchoCommandClient.dpr).

  Compila nos dois mundos a partir do MESMO fonte:
    FPC:    fpc -MDelphi -Sh -Fu..\..\src EchoCommandServer.dpr  (ou lazbuild EchoCommandServer.lpi)
    Delphi: abrir EchoCommandServer.dproj no IDE

  Uso: EchoCommandServer [nome-do-pipe] }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ELSE}
  {$APPTYPE CONSOLE}
{$ENDIF}

uses
  {$IFDEF FPC}
    {$IFDEF UNIX}
  cthreads, // threads reais no Unix: sem isso os eventos/condvars da lib falham em runtime
    {$ENDIF}
  {$ENDIF}
  SysUtils,
  Classes,
  SyncObjs,
  Pipes.Types,
  Pipes.Framing,
  Pipes.Server,
  Pipes.Commands;

type
  { Callbacks sao 'of object': o estado do sample vive nesta classe. }
  TEchoCommandServerApp = class
  private
    FServer: TNamedPipeServer;
    FRouter: TPipeCommandRouter;
    FConsoleLock: TCriticalSection;
    procedure Log(const AMsg: string);
    procedure OnPing(Sender: TObject; AConnId: TPipeConnectionId;
      const ACommand: string; const APayload: TBytes);
    procedure OnEco(Sender: TObject; AConnId: TPipeConnectionId;
      const ACommand: string; const APayload: TBytes);
    procedure OnSomarRequest(Sender: TObject; AConnId: TPipeConnectionId;
      const ACommand: string; const APayload: TBytes; out AReply: TBytes);
    procedure OnUnknownCommand(Sender: TObject; AConnId: TPipeConnectionId;
      const ACommand: string; const APayload: TBytes);
    procedure OnInvalidPayload(Sender: TObject; AConnId: TPipeConnectionId;
      const ACommand: string; const APayload: TBytes);
    procedure OnConn(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnDisc(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnErr(Sender: TObject; AConnId: TPipeConnectionId;
      const AError: string);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run(const APipeName: string);
  end;

constructor TEchoCommandServerApp.Create;
begin
  inherited Create;
  FConsoleLock := TCriticalSection.Create;
  FRouter := TPipeCommandRouter.Create;
  FRouter.RegisterCommand('PING', OnPing, PIPE_COMMAND_NO_LIMIT, 0); // corpo tem que vir vazio
  FRouter.RegisterCommand('ECO', OnEco, 1); // AMinSize = 1: corpo nao pode vir vazio
  FRouter.RegisterRequestCommand('SOMAR', OnSomarRequest, 1); // registro PROPRIO, independente do de mensagem
  FRouter.OnUnknownCommand := OnUnknownCommand;
  FRouter.OnInvalidPayload := OnInvalidPayload;
end;

destructor TEchoCommandServerApp.Destroy;
begin
  FServer.Free; // Stop no destructor
  FRouter.Free;
  FConsoleLock.Free;
  inherited;
end;

procedure TEchoCommandServerApp.Log(const AMsg: string);
begin
  FConsoleLock.Enter;
  try
    Writeln(AMsg);
  finally
    FConsoleLock.Leave;
  end;
end;

procedure TEchoCommandServerApp.OnPing(Sender: TObject;
  AConnId: TPipeConnectionId; const ACommand: string; const APayload: TBytes);
begin
  Log(Format('[conn %d] PING', [AConnId]));
  try
    FServer.SendBytes(AConnId, PipeEncodeCommandPayload('PONG', nil));
  except
    on E: EPipeError do
      Log(Format('[conn %d] PONG falhou (cliente caiu?): %s', [AConnId, E.Message]));
  end;
end;

procedure TEchoCommandServerApp.OnEco(Sender: TObject;
  AConnId: TPipeConnectionId; const ACommand: string; const APayload: TBytes);
var
  LTexto: string;
begin
  LTexto := PipeUtf8Decode(APayload);
  Log(Format('[conn %d] ECO: %s', [AConnId, LTexto]));
  try
    FServer.SendBytes(AConnId,
      PipeEncodeCommandPayload('ECO_OK', PipeUtf8Encode(UpperCase(LTexto))));
  except
    on E: EPipeError do
      Log(Format('[conn %d] ECO_OK falhou (cliente caiu?): %s', [AConnId, E.Message]));
  end;
end;

procedure TEchoCommandServerApp.OnSomarRequest(Sender: TObject;
  AConnId: TPipeConnectionId; const ACommand: string; const APayload: TBytes;
  out AReply: TBytes);
var
  LTexto: string;
  LEspaco: Integer;
  LA, LB: Integer;
begin
  LTexto := PipeUtf8Decode(APayload);
  Log(Format('[conn %d] SOMAR: %s', [AConnId, LTexto]));
  LEspaco := Pos(' ', LTexto);
  // Formato invalido ou nao-numerico: deixa a excecao propagar de proposito
  // (ver cabecalho do sample) — ExecuteRequest a transforma em reply de
  // erro pro cliente, o mesmo caminho de EPipeJSONError no EchoJsonServer.
  if (LEspaco = 0) or not TryStrToInt(Trim(Copy(LTexto, 1, LEspaco - 1)), LA)
     or not TryStrToInt(Trim(Copy(LTexto, LEspaco + 1, MaxInt)), LB) then
    raise Exception.CreateFmt(
      'formato esperado: "a b" com dois inteiros (recebido "%s")', [LTexto]);
  AReply := PipeUtf8Encode(IntToStr(LA + LB));
end;

procedure TEchoCommandServerApp.OnUnknownCommand(Sender: TObject;
  AConnId: TPipeConnectionId; const ACommand: string; const APayload: TBytes);
begin
  Log(Format('[conn %d] comando desconhecido: "%s"', [AConnId, ACommand]));
end;

procedure TEchoCommandServerApp.OnInvalidPayload(Sender: TObject;
  AConnId: TPipeConnectionId; const ACommand: string; const APayload: TBytes);
begin
  Log(Format('[conn %d] payload invalido para "%s" (%d byte(s))',
    [AConnId, ACommand, Length(APayload)]));
end;

procedure TEchoCommandServerApp.OnConn(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log(Format('[conn %d] conectou (%d cliente(s))', [AConnId, FServer.ClientCount]));
end;

procedure TEchoCommandServerApp.OnDisc(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log(Format('[conn %d] desconectou (%d cliente(s))', [AConnId, FServer.ClientCount]));
end;

procedure TEchoCommandServerApp.OnErr(Sender: TObject; AConnId: TPipeConnectionId;
  const AError: string);
begin
  Log(Format('[conn %d] erro: %s', [AConnId, AError]));
end;

procedure TEchoCommandServerApp.Run(const APipeName: string);
begin
  FServer := TNamedPipeServer.Create(APipeName);
  FServer.OnMessage := FRouter.HandleMessage; // mesma assinatura de TPipeMessageEvent
  FServer.OnRequest := FRouter.HandleRequest; // idem, TPipeRequestEvent
  FServer.OnClientConnected := OnConn;
  FServer.OnClientDisconnected := OnDisc;
  FServer.OnError := OnErr;
  FServer.Listen; // nao-blocante: acceptor + readers em threads proprias
  Log('escutando em "' + APipeName + '" - Enter encerra');
  Readln;
  FServer.Stop; // sincrono: join de tudo, drena callbacks em voo
  Log('encerrado.');
end;

var
  App: TEchoCommandServerApp;
  PipeName: string;
begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  if ParamCount >= 1 then
    PipeName := ParamStr(1)
  else
    PipeName := 'pipes_faa_echocommand';
  App := TEchoCommandServerApp.Create;
  try
    App.Run(PipeName);
  finally
    App.Free;
  end;
end.
