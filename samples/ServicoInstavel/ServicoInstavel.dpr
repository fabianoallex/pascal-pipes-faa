program ServicoInstavel;

{ Servidor "de propositos ruins" pra exercitar ClienteResiliente: a cada
  Request recebido, sorteia um de tres comportamentos:
    ~60% responde rapido e com sucesso;
    ~20% demora 2500 ms pra responder (mais que o timeout curto que o
         cliente usa por pedido) — o cliente desiste antes, e quando a
         resposta tardia chega o Request ja nao existe mais do lado dele
         (descartada silenciosamente, e' o comportamento documentado);
    ~20% levanta excecao no handler, simulando uma falha de negocio real
         (ex.: "CPF invalido") — a lib converte automaticamente em reply de
         erro; do lado do cliente isso vira EPipeError, nao EPipeTimeout.

  Uso: ServicoInstavel [nome-do-pipe]
  Compila nos dois mundos a partir do MESMO fonte:
    FPC:    fpc -MDelphi -Sh -Fu..\..\src ServicoInstavel.dpr  (ou lazbuild)
    Delphi: abrir ServicoInstavel.dproj no IDE }

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
  TServicoInstavelApp = class
  private
    FServer: TNamedPipeServer;
    FConsoleLock: TCriticalSection;
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

constructor TServicoInstavelApp.Create;
begin
  inherited Create;
  FConsoleLock := TCriticalSection.Create;
end;

destructor TServicoInstavelApp.Destroy;
begin
  FServer.Free; // Stop no destructor
  FConsoleLock.Free;
  inherited;
end;

procedure TServicoInstavelApp.Log(const AMsg: string);
begin
  FConsoleLock.Enter;
  try
    Writeln(AMsg);
  finally
    FConsoleLock.Leave;
  end;
end;

procedure TServicoInstavelApp.OnReq(Sender: TObject; AConnId: TPipeConnectionId;
  const ARequest: TBytes; out AReply: TBytes);
var
  LTexto: string;
  LSorte: Integer;
begin
  LTexto := PipeUtf8Decode(ARequest);
  LSorte := Random(10);
  if LSorte < 6 then
  begin
    Log(Format('[conn %d] "%s": respondendo rapido', [AConnId, LTexto]));
    AReply := PipeUtf8Encode('resultado:' + LTexto);
  end
  else if LSorte < 8 then
  begin
    Log(Format('[conn %d] "%s": simulando lentidao (2500 ms)...', [AConnId, LTexto]));
    Sleep(2500);
    Log(Format('[conn %d] "%s": respondeu tarde (cliente provavelmente ja desistiu)',
      [AConnId, LTexto]));
    AReply := PipeUtf8Encode('resultado:' + LTexto);
  end
  else
  begin
    Log(Format('[conn %d] "%s": simulando falha de negocio', [AConnId, LTexto]));
    raise Exception.Create('CPF invalido (falha simulada)');
  end;
end;

procedure TServicoInstavelApp.OnConn(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log(Format('[conn %d] conectou', [AConnId]));
end;

procedure TServicoInstavelApp.OnDisc(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log(Format('[conn %d] desconectou', [AConnId]));
end;

procedure TServicoInstavelApp.OnErr(Sender: TObject; AConnId: TPipeConnectionId;
  const AError: string);
begin
  Log(Format('[conn %d] erro: %s', [AConnId, AError]));
end;

procedure TServicoInstavelApp.Run(const APipeName: string);
begin
  Randomize;
  FServer := TNamedPipeServer.Create(APipeName);
  FServer.OnRequest := OnReq;
  FServer.OnClientConnected := OnConn;
  FServer.OnClientDisconnected := OnDisc;
  FServer.OnError := OnErr;
  FServer.Listen;
  Log('escutando em "' + APipeName + '" - Enter encerra.');
  Log('cada request tem ~60% de chance de ser rapido, ~20% de ser lento ' +
    '(2500 ms) e ~20% de falhar de proposito.');
  Readln;
  FServer.Stop;
  Log('encerrado.');
end;

var
  App: TServicoInstavelApp;
  PipeName: string;
begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  if ParamCount >= 1 then
    PipeName := ParamStr(1)
  else
    PipeName := 'pipes_faa_servico';
  App := TServicoInstavelApp.Create;
  try
    App.Run(PipeName);
  finally
    App.Free;
  end;
end.
