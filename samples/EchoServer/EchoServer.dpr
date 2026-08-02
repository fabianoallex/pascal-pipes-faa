program EchoServer;

{ Servidor de eco console: escuta no endereco dado (padrao 'pipes_faa_echo'),
  devolve cada mensagem recebida com o prefixo 'eco:' e responde requests
  sincronos (Request/RequestText do cliente) da mesma forma. Loga conexoes,
  desconexoes e erros. Enter encerra.

  Os handlers rodam em threads do pool (pdmPool, o padrao) — por isso o log
  passa por um critical section: WriteLn concorrente embaralha a saida.

  Compila nos dois mundos a partir do MESMO fonte:
    FPC:    fpc -MDelphi -Sh -Fu..\..\src EchoServer.dpr   (ou lazbuild EchoServer.lpi)
    Delphi: abrir EchoServer.dproj no IDE

  Uso: EchoServer [endereco] [tcp]

    EchoServer                    ptLocal em 'pipes_faa_echo' (padrao)
    EchoServer meu_pipe           ptLocal em 'meu_pipe'
    EchoServer *:5300 tcp         ptTcp em todas as interfaces, porta 5300

  O segundo parametro e' opcional e mantem o comportamento antigo intacto: sem
  ele, ptLocal como sempre. Ele existe para o sample EchoAndroid, que so' fala
  ptTcp/ptTls — um celular nao alcanca Named Pipe nem Unix Domain Socket.
  '*' e' atalho de '0.0.0.0'; '127.0.0.1:5300' escutaria SO' na propria maquina
  e o celular nao chegaria. }

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
    procedure Run(const AAddress: string; ATransport: TPipeTransport);
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

procedure TEchoServerApp.Run(const AAddress: string;
  ATransport: TPipeTransport);
begin
  FServer := TNamedPipeServer.Create(AAddress);
  FServer.Transport := ATransport;
  if ATransport = ptTcp then
    // Rede movel/Wi-Fi que dorme derruba conexao ociosa em silencio; sem isto o
    // servidor acumularia conexao zumbi de celular que saiu de alcance.
    FServer.HeartbeatIntervalMs := 15000;
  FServer.OnMessage := OnMsg;
  FServer.OnRequest := OnReq;
  FServer.OnClientConnected := OnConn;
  FServer.OnClientDisconnected := OnDisc;
  FServer.OnError := OnErr;
  FServer.Listen; // nao-blocante: acceptor + readers em threads proprias
  if ATransport = ptTcp then
    Log('escutando em "' + AAddress + '" (ptTcp) - Enter encerra')
  else
    Log('escutando em "' + AAddress + '" (ptLocal) - Enter encerra');
  Readln;
  FServer.Stop; // sincrono: join de tudo, drena callbacks em voo
  Log('encerrado.');
end;

var
  App: TEchoServerApp;
  Address: string;
  Transport: TPipeTransport;
begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  if ParamCount >= 1 then
    Address := ParamStr(1)
  else
    Address := 'pipes_faa_echo';
  Transport := ptLocal;
  if (ParamCount >= 2) and SameText(ParamStr(2), 'tcp') then
    Transport := ptTcp;
  App := TEchoServerApp.Create;
  try
    App.Run(Address, Transport);
  finally
    App.Free;
  end;
end.
