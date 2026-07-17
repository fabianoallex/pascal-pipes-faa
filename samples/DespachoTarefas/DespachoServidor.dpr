program DespachoServidor;

{ Demonstra endereçamento por conexao (SendBytes/SendText por ConnId) em vez
  de Broadcast: o operador digita "job <texto>" e o despachante escolhe UM
  worker conectado (round-robin sobre ClientIds) pra receber a tarefa — os
  outros workers nao veem nada. Mostra tambem ClientIds/ClientCount,
  MaxClients (workers alem do limite sao recusados) e DisconnectClient
  (kick manual de um worker).

  Uso: DespachoServidor [nome-do-pipe] [max-workers=3]
  Comandos no console: job <texto> | kick <connId> | list | sair

  Compila nos dois mundos a partir do MESMO fonte:
    FPC:    fpc -MDelphi -Sh -Fu..\..\src DespachoServidor.dpr  (ou lazbuild)
    Delphi: abrir DespachoServidor.dproj no IDE }

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
  TDespachoServidorApp = class
  private
    FServer: TNamedPipeServer;
    FConsoleLock: TCriticalSection;
    FProximoIdx: Integer; // round-robin sobre a posicao no snapshot de ClientIds
    procedure Log(const AMsg: string);
    function ProximoWorker: TPipeConnectionId;
    procedure ProcessarComando(const ALinha: string);
    procedure OnMsg(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure OnConn(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnDisc(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnErr(Sender: TObject; AConnId: TPipeConnectionId;
      const AError: string);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run(const APipeName: string; AMaxWorkers: Integer);
  end;

constructor TDespachoServidorApp.Create;
begin
  inherited Create;
  FConsoleLock := TCriticalSection.Create;
end;

destructor TDespachoServidorApp.Destroy;
begin
  FServer.Free; // Stop no destructor
  FConsoleLock.Free;
  inherited;
end;

procedure TDespachoServidorApp.Log(const AMsg: string);
begin
  FConsoleLock.Enter;
  try
    Writeln(AMsg);
  finally
    FConsoleLock.Leave;
  end;
end;

function TDespachoServidorApp.ProximoWorker: TPipeConnectionId;
var
  LIds: TArray<TPipeConnectionId>;
begin
  LIds := FServer.ClientIds;
  if Length(LIds) = 0 then
    Exit(PIPE_INVALID_CONNECTION);
  Result := LIds[FProximoIdx mod Length(LIds)];
  Inc(FProximoIdx);
end;

procedure TDespachoServidorApp.ProcessarComando(const ALinha: string);
var
  LEspaco: Integer;
  LVerbo, LResto: string;
  LWorker: TPipeConnectionId;
  LIds: TArray<TPipeConnectionId>;
  I: Integer;
begin
  LEspaco := Pos(' ', ALinha);
  if LEspaco = 0 then
  begin
    LVerbo := ALinha;
    LResto := '';
  end
  else
  begin
    LVerbo := Copy(ALinha, 1, LEspaco - 1);
    LResto := Trim(Copy(ALinha, LEspaco + 1, MaxInt));
  end;

  if SameText(LVerbo, 'job') then
  begin
    if LResto = '' then
    begin
      Log('uso: job <texto>');
      Exit;
    end;
    LWorker := ProximoWorker;
    if LWorker = PIPE_INVALID_CONNECTION then
    begin
      Log('nenhum worker conectado.');
      Exit;
    end;
    try
      FServer.SendText(LWorker, 'JOB:' + LResto);
      Log(Format('job "%s" despachado para worker %d', [LResto, LWorker]));
    except
      on E: EPipeError do
        Log('falha ao despachar (worker caiu na hora?): ' + E.Message);
    end;
  end
  else if SameText(LVerbo, 'kick') then
  begin
    LWorker := TPipeConnectionId(StrToInt64Def(LResto, 0));
    if LWorker = 0 then
      Log('uso: kick <connId> (veja os ids com "list")')
    else
    begin
      FServer.DisconnectClient(LWorker);
      Log(Format('worker %d desconectado (kick).', [LWorker]));
    end;
  end
  else if SameText(LVerbo, 'list') then
  begin
    LIds := FServer.ClientIds;
    if Length(LIds) = 0 then
      Log('nenhum worker conectado.')
    else
    begin
      Log(Format('%d worker(s) conectado(s):', [Length(LIds)]));
      for I := 0 to High(LIds) do
        Log('  worker ' + IntToStr(LIds[I]));
    end;
  end
  else
    Log('comandos: job <texto> | kick <connId> | list | sair');
end;

procedure TDespachoServidorApp.OnMsg(Sender: TObject; AConnId: TPipeConnectionId;
  const AData: TBytes);
var
  LTexto: string;
begin
  LTexto := PipeUtf8Decode(AData);
  if Pos('OK:', LTexto) = 1 then
    Log(Format('worker %d concluiu: %s', [AConnId, Copy(LTexto, 4, MaxInt)]))
  else
    Log(Format('[worker %d] mensagem inesperada: %s', [AConnId, LTexto]));
end;

procedure TDespachoServidorApp.OnConn(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log(Format('worker %d conectou (%d online)', [AConnId, FServer.ClientCount]));
end;

procedure TDespachoServidorApp.OnDisc(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log(Format('worker %d saiu (%d online)', [AConnId, FServer.ClientCount]));
end;

procedure TDespachoServidorApp.OnErr(Sender: TObject; AConnId: TPipeConnectionId;
  const AError: string);
begin
  Log(Format('[worker %d] erro: %s', [AConnId, AError]));
end;

procedure TDespachoServidorApp.Run(const APipeName: string; AMaxWorkers: Integer);
var
  LComando: string;
begin
  FServer := TNamedPipeServer.Create(APipeName);
  FServer.MaxClients := AMaxWorkers;
  FServer.OnClientConnected := OnConn;
  FServer.OnClientDisconnected := OnDisc;
  FServer.OnMessage := OnMsg;
  FServer.OnError := OnErr;
  FServer.Listen;
  Log(Format('despachante escutando em "%s" (max %d workers).',
    [APipeName, AMaxWorkers]));
  Log('rode DespachoWorker (uma ou mais instancias) noutro terminal.');
  Log('comandos: job <texto> | kick <connId> | list | sair');
  repeat
    Write('> ');
    Readln(LComando);
    LComando := Trim(LComando);
    if (LComando <> '') and not SameText(LComando, 'sair') then
      ProcessarComando(LComando);
  until SameText(LComando, 'sair');
  FServer.Stop;
  Log('encerrado.');
end;

var
  App: TDespachoServidorApp;
  PipeName: string;
  MaxWorkers: Integer;
begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  if ParamCount >= 1 then
    PipeName := ParamStr(1)
  else
    PipeName := 'pipes_faa_despacho';
  MaxWorkers := 3;
  if ParamCount >= 2 then
    MaxWorkers := StrToIntDef(ParamStr(2), 3);
  App := TDespachoServidorApp.Create;
  try
    App.Run(PipeName, MaxWorkers);
  finally
    App.Free;
  end;
end.
