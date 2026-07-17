program RpcConcorrenteServidor;

{ Servidor de apoio pro RpcConcorrenteCliente: recebe "req:<id>", dorme um
  tempo aleatorio curto (pra garantir que varias Requests fiquem em voo ao
  mesmo tempo, inclusive vindas da MESMA conexao) e responde "rep:<id>:<f(id)>"
  com uma funcao deterministica simples. O cliente e' quem faz o trabalho de
  provar a garantia: cada thread confere que o <id> que volta e' exatamente o
  que ela mandou.

  Uso: RpcConcorrenteServidor [nome-do-pipe]
  Compila nos dois mundos a partir do MESMO fonte:
    FPC:    fpc -MDelphi -Sh -Fu..\..\src RpcConcorrenteServidor.dpr  (ou lazbuild)
    Delphi: abrir RpcConcorrenteServidor.dproj no IDE }

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
  Pipes.Threading,
  Pipes.Framing,
  Pipes.Server;

type
  TRpcConcorrenteServidorApp = class
  private
    FServer: TNamedPipeServer;
    FConsoleLock: TCriticalSection;
    FTotalAtendido: Integer;
    procedure Log(const AMsg: string);
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

constructor TRpcConcorrenteServidorApp.Create;
begin
  inherited Create;
  FConsoleLock := TCriticalSection.Create;
end;

destructor TRpcConcorrenteServidorApp.Destroy;
begin
  FServer.Free; // Stop no destructor
  FConsoleLock.Free;
  inherited;
end;

procedure TRpcConcorrenteServidorApp.Log(const AMsg: string);
begin
  FConsoleLock.Enter;
  try
    Writeln(AMsg);
  finally
    FConsoleLock.Leave;
  end;
end;

{ Extrai o Int64 apos o prefixo "req:" de ATexto. -1 se malformado. }
function LerId(const ATexto: string): Int64;
const
  PREFIXO = 'req:';
begin
  if Copy(ATexto, 1, Length(PREFIXO)) = PREFIXO then
    Result := StrToInt64Def(Copy(ATexto, Length(PREFIXO) + 1, MaxInt), -1)
  else
    Result := -1;
end;

procedure TRpcConcorrenteServidorApp.OnReq(Sender: TObject; AConnId: TPipeConnectionId;
  const ARequest: TBytes; out AReply: TBytes);
var
  LId: Int64;
  LResultado: Int64;
  LAtendido: Integer;
begin
  LId := LerId(PipeUtf8Decode(ARequest));
  if LId < 0 then
    raise Exception.CreateFmt('request malformado: "%s"', [PipeUtf8Decode(ARequest)]);

  // Sleep aleatorio: sem isso as respostas sairiam rapido demais pra
  // realmente sobrepor Requests concorrentes no teste do cliente.
  Sleep(5 + Random(60));
  LResultado := LId * 31 + 7; // funcao deterministica simples pro cliente validar
  AReply := PipeUtf8Encode(Format('rep:%d:%d', [LId, LResultado]));

  LAtendido := PipeAtomicInc(FTotalAtendido);
  if LAtendido mod 50 = 0 then
    Log(Format('[conn %d] %d requests atendidos ate agora', [AConnId, LAtendido]));
end;

procedure TRpcConcorrenteServidorApp.OnConn(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log(Format('[conn %d] conectou', [AConnId]));
end;

procedure TRpcConcorrenteServidorApp.OnDisc(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log(Format('[conn %d] desconectou', [AConnId]));
end;

procedure TRpcConcorrenteServidorApp.OnErr(Sender: TObject; AConnId: TPipeConnectionId;
  const AError: string);
begin
  Log(Format('[conn %d] erro: %s', [AConnId, AError]));
end;

procedure TRpcConcorrenteServidorApp.Run(const APipeName: string);
begin
  Randomize;
  FServer := TNamedPipeServer.Create(APipeName);
  FServer.DispatchMode := pdmPool; // padrao, explicito: precisa atender varias Requests ao mesmo tempo
  FServer.OnRequest := OnReq;
  FServer.OnClientConnected := OnConn;
  FServer.OnClientDisconnected := OnDisc;
  FServer.OnError := OnErr;
  FServer.Listen;
  Log('escutando em "' + APipeName + '" - Enter encerra.');
  Readln;
  FServer.Stop;
  Log(Format('encerrado. total de requests atendidos: %d.', [FTotalAtendido]));
end;

var
  App: TRpcConcorrenteServidorApp;
  PipeName: string;
begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  if ParamCount >= 1 then
    PipeName := ParamStr(1)
  else
    PipeName := 'pipes_faa_rpc_concorrente';
  App := TRpcConcorrenteServidorApp.Create;
  try
    App.Run(PipeName);
  finally
    App.Free;
  end;
end.
