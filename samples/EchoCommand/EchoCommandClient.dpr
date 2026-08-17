program EchoCommandClient;

{ Cliente de eco console com roteamento por COMANDO (ver EchoCommandServer.dpr
  e README.md secao "Comandos"). Usa TPipeCommandRouter tambem do lado do
  cliente, so' para receber as respostas fire-and-forget (PONG/ECO_OK) — o
  envio usa PipeSendCommand/PipeSendCommandText/PipeRequestCommand/
  PipeRequestCommandText, os wrappers de conveniencia de Pipes.Commands.pas
  que montam o envelope por cima de SendBytes/Request (ver README.md).

  Le linhas do teclado:
    ping         -> manda o comando PING fire-and-forget (corpo vazio); a
                    confirmacao assincrona (PONG) chega em OnMessage
    eco <texto>  -> idem, comando ECO com <texto> como corpo; confirmacao
                    ECO_OK chega em OnMessage
    ?soma <a> <b> -> Request sincrono do comando SOMAR (RPC, timeout 5s); o
                    reply com a soma chega como retorno da chamada
    ?ping        -> Request sincrono do comando PING — PING so' esta
                    registrado do lado OnMessage (RegisterCommand), nao do
                    lado OnRequest (RegisterRequestCommand): os dois registros
                    sao independentes, entao isto dispara o caminho de
                    "comando desconhecido" do request-reply (HandleRequest
                    levanta, vira reply de erro, o cliente ve EPipeError) —
                    vitrine de proposito do contrato "HandleRequest sempre
                    levanta" (ver cabecalho de Pipes.Commands.pas)
    sair         -> encerra (linha vazia tambem)

  Compila nos dois mundos a partir do MESMO fonte:
    FPC:    fpc -MDelphi -Sh -Fu..\..\src EchoCommandClient.dpr  (ou lazbuild EchoCommandClient.lpi)
    Delphi: abrir EchoCommandClient.dproj no IDE

  Uso: EchoCommandClient [nome-do-pipe] }

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
  StrUtils,
  Classes,
  SyncObjs,
  Pipes.Types,
  Pipes.Framing,
  Pipes.Client,
  Pipes.Commands;

type
  { Callbacks sao 'of object': o estado do sample vive nesta classe. }
  TEchoCommandClientApp = class
  private
    FClient: TNamedPipeClient;
    FRouter: TPipeCommandRouter;
    FConsoleLock: TCriticalSection;
    procedure Log(const AMsg: string);
    procedure OnPong(Sender: TObject; AConnId: TPipeConnectionId;
      const ACommand: string; const APayload: TBytes);
    procedure OnEcoOk(Sender: TObject; AConnId: TPipeConnectionId;
      const ACommand: string; const APayload: TBytes);
    procedure OnUnknownCommand(Sender: TObject; AConnId: TPipeConnectionId;
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

constructor TEchoCommandClientApp.Create;
begin
  inherited Create;
  FConsoleLock := TCriticalSection.Create;
  FRouter := TPipeCommandRouter.Create;
  FRouter.RegisterCommand('PONG', OnPong, PIPE_COMMAND_NO_LIMIT, 0);
  FRouter.RegisterCommand('ECO_OK', OnEcoOk, 1);
  FRouter.OnUnknownCommand := OnUnknownCommand;
end;

destructor TEchoCommandClientApp.Destroy;
begin
  FClient.Free; // Disconnect no destructor
  FRouter.Free;
  FConsoleLock.Free;
  inherited;
end;

procedure TEchoCommandClientApp.Log(const AMsg: string);
begin
  FConsoleLock.Enter;
  try
    Writeln(AMsg);
  finally
    FConsoleLock.Leave;
  end;
end;

procedure TEchoCommandClientApp.OnPong(Sender: TObject;
  AConnId: TPipeConnectionId; const ACommand: string; const APayload: TBytes);
begin
  Log('PONG recebido.');
end;

procedure TEchoCommandClientApp.OnEcoOk(Sender: TObject;
  AConnId: TPipeConnectionId; const ACommand: string; const APayload: TBytes);
begin
  Log('ECO_OK: ' + PipeUtf8Decode(APayload));
end;

procedure TEchoCommandClientApp.OnUnknownCommand(Sender: TObject;
  AConnId: TPipeConnectionId; const ACommand: string; const APayload: TBytes);
begin
  Log('comando desconhecido recebido: "' + ACommand + '"');
end;

procedure TEchoCommandClientApp.OnConn(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log('conectado.');
end;

procedure TEchoCommandClientApp.OnDisc(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log('desconectado do servidor.');
end;

procedure TEchoCommandClientApp.OnErr(Sender: TObject; AConnId: TPipeConnectionId;
  const AError: string);
begin
  Log('erro: ' + AError);
end;

procedure TEchoCommandClientApp.Run(const APipeName: string);
var
  LLinha, LTexto: string;
  LEspaco: Integer;
begin
  FClient := TNamedPipeClient.Create(APipeName);
  FClient.OnMessage := FRouter.HandleMessage; // mesma assinatura de TPipeMessageEvent
  FClient.OnConnected := OnConn;
  FClient.OnDisconnected := OnDisc;
  FClient.OnError := OnErr;
  FClient.Connect(5000); // re-tenta ate 5 s (cobre servidor ainda subindo)
  Log('conectado a "' + APipeName + '". Digite "ping", "eco <texto>", ' +
    '"?soma <a> <b>", "?ping" ou "sair".');
  while True do
  begin
    Readln(LLinha);
    if (LLinha = '') or SameText(LLinha, 'sair') then
      Break;

    try
      if SameText(LLinha, 'ping') then
        PipeSendCommand(FClient, 'PING', nil)
      else if StartsText('eco ', LLinha) then
      begin
        LEspaco := Pos(' ', LLinha);
        LTexto := Copy(LLinha, LEspaco + 1, MaxInt);
        PipeSendCommandText(FClient, 'ECO', LTexto);
      end
      else if SameText(LLinha, '?ping') then
      begin
        // PING so' tem handler do lado OnMessage: isto dispara de proposito
        // o "comando desconhecido" do lado request-reply (ver cabecalho).
        try
          PipeRequestCommand(FClient, 'PING', nil, 5000);
        except
          on E: EPipeError do
            Log('request "?ping" falhou como esperado: ' + E.Message);
        end;
      end
      else if StartsText('?soma ', LLinha) then
      begin
        LTexto := Copy(LLinha, Length('?soma ') + 1, MaxInt);
        try
          Log('reply sincrono: ' +
            PipeRequestCommandText(FClient, 'SOMAR', LTexto, 5000));
        except
          on E: EPipeError do
            Log('request "?soma" falhou: ' + E.Message);
        end;
      end
      else
        Log('formato esperado: "ping", "eco <texto>", "?soma <a> <b>" ou "?ping"');
    except
      on E: EPipeError do
        Log('falha no envio: ' + E.Message);
    end;
  end;
  FClient.Disconnect; // sincrono e idempotente
  Log('encerrado.');
end;

var
  App: TEchoCommandClientApp;
  PipeName: string;
begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  if ParamCount >= 1 then
    PipeName := ParamStr(1)
  else
    PipeName := 'pipes_faa_echocommand';
  App := TEchoCommandClientApp.Create;
  try
    App.Run(PipeName);
  finally
    App.Free;
  end;
end.
