program EchoFailoverClient;

{ Cliente de eco console com FailoverAddresses (ver README.md secao
  "Failover de endereco"). Nenhum servidor novo precisa existir: rode DOIS
  EchoServer.exe (ou mais) com nomes diferentes - o primario e um ou mais
  alternativos - e este cliente conecta no primario, migrando sozinho para um
  alternativo se ele cair.

  Mesma interacao do EchoClient (texto = SendText assincrono; ?texto =
  RequestText sincrono; sair encerra), mais um log de qual endereco a sessao
  ATUAL usa a cada OnConnected - e' o que deixa a migracao visivel.

  Roteiro de 2 minutos:
    1) EchoServer.exe pipes_faa_primario
    2) EchoServer.exe pipes_faa_backup
    3) EchoFailoverClient.exe pipes_faa_primario pipes_faa_backup
    4) troque mensagens, confirme "endereco ativo: pipes_faa_primario"
    5) va ao passo 1 e aperte Enter (derruba o primario)
    6) troque mensagens de novo: apos AutoReconnect migrar, o log mostra
       "endereco ativo: pipes_faa_backup" sem reiniciar o cliente
    7) opcional: suba o primario de novo (passo 1), derrube o backup (passo
       2) - o cliente volta a preferir o primario, nao "avanca" para um
       terceiro endereco que nao existe aqui (ver docs/ARQUITETURA.md, secao
       de failover, sobre sessao DURAVEL)

  Compila nos dois mundos a partir do MESMO fonte:
    FPC:    fpc -MDelphi -Sh -Fu..\..\src EchoFailoverClient.dpr  (ou lazbuild EchoFailoverClient.lpi)
    Delphi: abrir EchoFailoverClient.dproj no IDE

  Uso: EchoFailoverClient <endereco-primario> [endereco-alternativo ...] }

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
  TEchoFailoverClientApp = class
  private
    FClient: TPipeClient;
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
    procedure Run(const APrimario: string; const AAlternativos: TArray<string>);
  end;

constructor TEchoFailoverClientApp.Create;
begin
  inherited Create;
  FConsoleLock := TCriticalSection.Create;
end;

destructor TEchoFailoverClientApp.Destroy;
begin
  FClient.Free; // Disconnect no destructor
  FConsoleLock.Free;
  inherited;
end;

procedure TEchoFailoverClientApp.Log(const AMsg: string);
begin
  FConsoleLock.Enter;
  try
    Writeln(AMsg);
  finally
    FConsoleLock.Leave;
  end;
end;

procedure TEchoFailoverClientApp.OnMsg(Sender: TObject;
  AConnId: TPipeConnectionId; const AData: TBytes);
begin
  Log('eco assincrono: ' + PipeUtf8Decode(AData));
end;

procedure TEchoFailoverClientApp.OnConn(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  // E' este log que torna a migracao visivel: o mesmo evento de sempre,
  // mais ActiveAddress dizendo QUAL endereco a sessao nova esta usando.
  Log('conectado - endereco ativo: ' + FClient.ActiveAddress);
end;

procedure TEchoFailoverClientApp.OnDisc(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  // Dispara tanto numa queda de verdade (e ai' o AutoReconnect assume, com
  // o proximo OnConnected mostrando pra onde migrou) quanto num Disconnect
  // deliberado (o "sair" do proprio usuario) - por isso o texto e' neutro,
  // sem prometer uma reconexao que pode nao vir.
  Log('desconectado.');
end;

procedure TEchoFailoverClientApp.OnErr(Sender: TObject;
  AConnId: TPipeConnectionId; const AError: string);
begin
  Log('erro: ' + AError);
end;

procedure TEchoFailoverClientApp.Run(const APrimario: string;
  const AAlternativos: TArray<string>);
var
  LLinha, LReply: string;
begin
  FClient := TPipeClient.Create(APrimario);
  FClient.FailoverAddresses := AAlternativos;
  FClient.AutoReconnect := True;
  FClient.ReconnectDelayMs := 500; // mais responsivo que o padrao (2000) pro roteiro
  FClient.OnMessage := OnMsg;
  FClient.OnConnected := OnConn;
  FClient.OnDisconnected := OnDisc;
  FClient.OnError := OnErr;
  FClient.Connect(8000); // orcamento dividido entre primario + alternativos
  Log('Digite texto, ?texto (RPC) ou sair.');
  while True do
  begin
    Readln(LLinha);
    if (LLinha = '') or SameText(LLinha, 'sair') then
      Break;
    try
      if LLinha[1] = '?' then
      begin
        LReply := FClient.RequestText(Copy(LLinha, 2, MaxInt), 5000);
        Log('reply sincrono (via ' + FClient.ActiveAddress + '): ' + LReply);
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
  App: TEchoFailoverClientApp;
  LAlternativos: TArray<string>;
  I: Integer;
begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  if ParamCount < 1 then
  begin
    Writeln('Uso: EchoFailoverClient <endereco-primario> [endereco-alternativo ...]');
    Halt(1);
  end;
  SetLength(LAlternativos, ParamCount - 1);
  for I := 2 to ParamCount do
    LAlternativos[I - 2] := ParamStr(I);

  App := TEchoFailoverClientApp.Create;
  try
    App.Run(ParamStr(1), LAlternativos);
  finally
    App.Free;
  end;
end.
