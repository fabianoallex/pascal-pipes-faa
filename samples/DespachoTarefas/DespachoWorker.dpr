program DespachoWorker;

{ Worker do sample DespachoTarefas: conecta no DespachoServidor e fica
  esperando jobs endereçados especificamente a ele (nunca broadcast — o
  servidor escolhe um worker por vez via SendText/ConnId). Ao terminar um
  job, devolve "OK:<job>" pro servidor. Rode varias instancias (ate o limite
  MaxClients do servidor) pra ver o despacho round-robin na pratica.

  Uso: DespachoWorker [nome-do-pipe]
  Compila nos dois mundos a partir do MESMO fonte:
    FPC:    fpc -MDelphi -Sh -Fu..\..\src DespachoWorker.dpr  (ou lazbuild)
    Delphi: abrir DespachoWorker.dproj no IDE }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ELSE}
  {$APPTYPE CONSOLE}
{$ENDIF}

uses
  {$IFDEF FPC}
    {$IFDEF UNIX}
  cthreads,
    {$ENDIF}
  {$ENDIF}
  SysUtils,
  Classes,
  SyncObjs,
  Pipes.Types,
  Pipes.Framing,
  Pipes.Client;

type
  TDespachoWorkerApp = class
  private
    FClient: TNamedPipeClient;
    FConsoleLock: TCriticalSection;
    procedure Log(const AMsg: string);
    procedure OnMsg(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure OnConn(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnDisc(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnErr(Sender: TObject; AConnId: TPipeConnectionId;
      const AError: string);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run(const APipeName: string);
  end;

constructor TDespachoWorkerApp.Create;
begin
  inherited Create;
  FConsoleLock := TCriticalSection.Create;
end;

destructor TDespachoWorkerApp.Destroy;
begin
  FClient.Free; // Disconnect no destructor
  FConsoleLock.Free;
  inherited;
end;

procedure TDespachoWorkerApp.Log(const AMsg: string);
begin
  FConsoleLock.Enter;
  try
    Writeln(AMsg);
  finally
    FConsoleLock.Leave;
  end;
end;

procedure TDespachoWorkerApp.OnMsg(Sender: TObject; AConnId: TPipeConnectionId;
  const AData: TBytes);
var
  LTexto, LJob: string;
begin
  LTexto := PipeUtf8Decode(AData);
  if Pos('JOB:', LTexto) <> 1 then
  begin
    Log('mensagem inesperada: ' + LTexto);
    Exit;
  end;
  LJob := Copy(LTexto, 5, MaxInt);
  Log('processando: ' + LJob);
  Sleep(300 + Random(1200)); // simula trabalho
  Log('concluido: ' + LJob);
  try
    FClient.SendText('OK:' + LJob);
  except
    on E: EPipeError do
      Log('falha ao confirmar (despachante caiu?): ' + E.Message);
  end;
end;

procedure TDespachoWorkerApp.OnConn(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log('conectado ao despachante.');
end;

procedure TDespachoWorkerApp.OnDisc(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log('conexao com o despachante caiu.');
end;

procedure TDespachoWorkerApp.OnErr(Sender: TObject; AConnId: TPipeConnectionId;
  const AError: string);
begin
  Log('erro: ' + AError);
end;

procedure TDespachoWorkerApp.Run(const APipeName: string);
begin
  Randomize;
  FClient := TNamedPipeClient.Create(APipeName);
  FClient.AutoReconnect := True;
  FClient.OnMessage := OnMsg;
  FClient.OnConnected := OnConn;
  FClient.OnDisconnected := OnDisc;
  FClient.OnError := OnErr;
  FClient.Connect(3000);
  Log('pronto - aguardando jobs do despachante. Enter encerra.');
  Readln;
  FClient.Disconnect;
  Log('encerrado.');
end;

var
  App: TDespachoWorkerApp;
  PipeName: string;
begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  if ParamCount >= 1 then
    PipeName := ParamStr(1)
  else
    PipeName := 'pipes_faa_despacho';
  App := TDespachoWorkerApp.Create;
  try
    App.Run(PipeName);
  finally
    App.Free;
  end;
end.
