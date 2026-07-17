program EchoServer;

{ Servidor de eco console: escuta no pipe dado (padrao 'pipes_faa_echo'),
  devolve cada mensagem recebida com o prefixo 'eco:' e responde requests
  sincronos (Request/RequestText do cliente) da mesma forma. Loga conexoes,
  desconexoes e erros. Enter encerra.

  Os handlers rodam em threads do pool (pdmPool, o padrao) — por isso o log
  passa por um critical section: WriteLn concorrente embaralha a saida.

  Compila nos dois mundos a partir do MESMO fonte:
    FPC:    fpc -MDelphi -Sh -Fu..\..\src EchoServer.dpr   (ou lazbuild EchoServer.lpi)
    Delphi: abrir EchoServer.dproj no IDE

  Uso: EchoServer [nome-do-pipe] }

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
  Pipes.Server;

type
  { Callbacks sao 'of object': o estado do sample vive nesta classe. }
  TEchoServerApp = class
  private
    FServer: TNamedPipeServer;
    FConsoleLock: TCriticalSection;
    procedure Log(const AMsg: string);
    procedure OnMsg(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure OnReq(Sender: TObject; AConnId: TPipeConnectionId;
      const ARequest: TBytes; out AReply: TBytes);
    procedure OnConn(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnDisc(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnErr(Sender: TObject; AConnId: TPipeConnectionId;
      const AError: string);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run(const APipeName: string);
  end;

constructor TEchoServerApp.Create;
begin
  inherited Create;
  FConsoleLock := TCriticalSection.Create;
end;

destructor TEchoServerApp.Destroy;
begin
  FServer.Free; // Stop no destructor
  FConsoleLock.Free;
  inherited;
end;

procedure TEchoServerApp.Log(const AMsg: string);
begin
  FConsoleLock.Enter;
  try
    Writeln(AMsg);
  finally
    FConsoleLock.Leave;
  end;
end;

procedure TEchoServerApp.OnMsg(Sender: TObject; AConnId: TPipeConnectionId;
  const AData: TBytes);
var
  LTexto: string;
begin
  LTexto := PipeUtf8Decode(AData);
  Log(Format('[conn %d] mensagem: %s', [AConnId, LTexto]));
  try
    FServer.SendText(AConnId, 'eco:' + LTexto);
  except
    on E: EPipeError do
      Log(Format('[conn %d] eco falhou (cliente caiu?): %s', [AConnId, E.Message]));
  end;
end;

procedure TEchoServerApp.OnReq(Sender: TObject; AConnId: TPipeConnectionId;
  const ARequest: TBytes; out AReply: TBytes);
var
  LTexto: string;
begin
  LTexto := PipeUtf8Decode(ARequest);
  Log(Format('[conn %d] request: %s', [AConnId, LTexto]));
  AReply := PipeUtf8Encode('eco:' + LTexto); // a lib envia o reply com o corrId certo
end;

procedure TEchoServerApp.OnConn(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log(Format('[conn %d] conectou (%d cliente(s))', [AConnId, FServer.ClientCount]));
end;

procedure TEchoServerApp.OnDisc(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log(Format('[conn %d] desconectou (%d cliente(s))', [AConnId, FServer.ClientCount]));
end;

procedure TEchoServerApp.OnErr(Sender: TObject; AConnId: TPipeConnectionId;
  const AError: string);
begin
  Log(Format('[conn %d] erro: %s', [AConnId, AError]));
end;

procedure TEchoServerApp.Run(const APipeName: string);
begin
  FServer := TNamedPipeServer.Create(APipeName);
  FServer.OnMessage := OnMsg;
  FServer.OnRequest := OnReq;
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
  App: TEchoServerApp;
  PipeName: string;
begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  if ParamCount >= 1 then
    PipeName := ParamStr(1)
  else
    PipeName := 'pipes_faa_echo';
  App := TEchoServerApp.Create;
  try
    App.Run(PipeName);
  finally
    App.Free;
  end;
end.
