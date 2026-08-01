program EchoClient;

{ Cliente de eco console: conecta ao pipe dado (padrao 'pipes_faa_echo') e le
  linhas do teclado:
    texto      -> SendText (fire-and-forget); o eco assincrono chega via
                  OnMessage, numa thread do pool
    ?texto     -> RequestText (RPC sincrono com timeout de 5 s); o reply chega
                  como retorno da chamada, correlacionado pela lib
    sair       -> encerra (linha vazia tambem)

  Compila nos dois mundos a partir do MESMO fonte:
    FPC:    fpc -MDelphi -Sh -Fu..\..\src EchoClient.dpr   (ou lazbuild EchoClient.lpi)
    Delphi: abrir EchoClient.dproj no IDE

  Uso: EchoClient [endereco] [tcp]

    EchoClient                       ptLocal em 'pipes_faa_echo' (padrao)
    EchoClient meu_pipe              ptLocal em 'meu_pipe'
    EchoClient 192.168.0.10:5300 tcp ptTcp

  O segundo parametro e' opcional e nao muda o comportamento antigo. Serve para
  conferir do PC um servidor ptTcp antes de culpar o celular (ver o sample
  EchoAndroid). }

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
  Pipes.Client;

type
  { Callbacks sao 'of object': o estado do sample vive nesta classe. }
  TEchoClientApp = class
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
    procedure Run(const AAddress: string; ATransport: TPipeTransport);
  end;

constructor TEchoClientApp.Create;
begin
  inherited Create;
  FConsoleLock := TCriticalSection.Create;
end;

destructor TEchoClientApp.Destroy;
begin
  FClient.Free; // Disconnect no destructor
  FConsoleLock.Free;
  inherited;
end;

procedure TEchoClientApp.Log(const AMsg: string);
begin
  FConsoleLock.Enter;
  try
    Writeln(AMsg);
  finally
    FConsoleLock.Leave;
  end;
end;

procedure TEchoClientApp.OnMsg(Sender: TObject; AConnId: TPipeConnectionId;
  const AData: TBytes);
begin
  Log('eco assincrono: ' + PipeUtf8Decode(AData));
end;

procedure TEchoClientApp.OnConn(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log('conectado.');
end;

procedure TEchoClientApp.OnDisc(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log('desconectado do servidor.');
end;

procedure TEchoClientApp.OnErr(Sender: TObject; AConnId: TPipeConnectionId;
  const AError: string);
begin
  Log('erro: ' + AError);
end;

procedure TEchoClientApp.Run(const AAddress: string;
  ATransport: TPipeTransport);
var
  LLinha, LReply: string;
begin
  FClient := TNamedPipeClient.Create(AAddress);
  FClient.Transport := ATransport;
  FClient.OnMessage := OnMsg;
  FClient.OnConnected := OnConn;
  FClient.OnDisconnected := OnDisc;
  FClient.OnError := OnErr;
  FClient.Connect(5000); // re-tenta ate 5 s (cobre servidor ainda subindo)
  Log('conectado a "' + AAddress + '". Digite texto, ?texto (RPC) ou sair.');
  while True do
  begin
    Readln(LLinha);
    if (LLinha = '') or SameText(LLinha, 'sair') then
      Break;
    try
      if LLinha[1] = '?' then
      begin
        LReply := FClient.RequestText(Copy(LLinha, 2, MaxInt), 5000);
        Log('reply sincrono: ' + LReply);
      end
      else
        FClient.SendText(LLinha);
    except
      on E: EPipeError do
        Log('falha no envio: ' + E.Message);
    end;
  end;
  FClient.Disconnect; // sincrono e idempotente
  Log('encerrado.');
end;

var
  App: TEchoClientApp;
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
  App := TEchoClientApp.Create;
  try
    App.Run(Address, Transport);
  finally
    App.Free;
  end;
end.
