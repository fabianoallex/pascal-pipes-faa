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

  Uso: EchoClient [endereco] [tcp|tls [dir-pki] [nome-do-cliente]]

    EchoClient                       ptLocal em 'pipes_faa_echo' (padrao)
    EchoClient meu_pipe              ptLocal em 'meu_pipe'
    EchoClient 192.168.0.10:5300 tcp ptTcp
    EchoClient 192.168.0.10:5300 tls <dir-pki>
    EchoClient ... tls <dir-pki> cli        apresenta certificado (mTLS)

  <dir-pki> relativo vale a partir do diretorio ATUAL; o build do FPC e o do
  Delphi deixam o exe em niveis diferentes da arvore. Na duvida, use caminho
  absoluto.

  Os parametros a partir do segundo sao opcionais e nao mudam o comportamento
  antigo. Servem para conferir do PC um servidor ptTcp/ptTls antes de culpar o
  celular (ver o sample EchoAndroid).

  No modo tls, CaFile aponta para o ca_cert.pem do diretorio dado. ATENCAO: no
  backend SChannel (padrao no Windows) o CaFile do CLIENTE e' IGNORADO — o
  Windows valida contra o trust store do SO, onde a PKI de teste nao esta, e a
  conexao sera recusada. Para conferir um servidor de PKI propria a partir do
  PC, compile este sample com -dPIPES_OPENSSL (ou rode-o no Linux). }

{$I pipes.inc}

{$IFNDEF FPC}
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
    procedure Run(const AAddress: string; ATransport: TPipeTransport;
      const APkiDir, ACliCert: string);
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
  ATransport: TPipeTransport; const APkiDir, ACliCert: string);
var
  LLinha, LReply, LDir: string;
begin
  FClient := TNamedPipeClient.Create(AAddress);
  FClient.Transport := ATransport;
  if ATransport = ptTls then
  begin
    LDir := IncludeTrailingPathDelimiter(APkiDir);
    // CA que assina o servidor. Sem isto o cliente valida contra o trust store
    // do SO, onde uma PKI propria nao esta.
    FClient.TlsOptions.CaFile := LDir + 'ca_cert.pem';
    if ACliCert <> '' then
    begin
      // mTLS: so' apresenta certificado se pedirem um. O arquivo depende do
      // backend compilado, igual ao lado do servidor.
      {$IFDEF PIPES_SCHANNEL}
      FClient.TlsOptions.CertFile := LDir + ACliCert + '.pfx';
      {$ELSE}
      FClient.TlsOptions.CertFile := LDir + ACliCert + '_cert.pem';
      FClient.TlsOptions.KeyFile := LDir + ACliCert + '_key.pem';
      {$ENDIF}
    end;
  end;
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
  Address, PkiDir, CliCert: string;
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
  PkiDir := '';
  CliCert := '';
  if ParamCount >= 2 then
  begin
    if SameText(ParamStr(2), 'tcp') then
      Transport := ptTcp
    else if SameText(ParamStr(2), 'tls') then
    begin
      Transport := ptTls;
      if ParamCount < 3 then
      begin
        Writeln('modo tls exige o diretorio da PKI.');
        Halt(2);
      end;
      PkiDir := ParamStr(3);
      if ParamCount >= 4 then
        CliCert := ParamStr(4);
    end;
  end;
  App := TEchoClientApp.Create;
  try
    App.Run(Address, Transport, PkiDir, CliCert);
  finally
    App.Free;
  end;
end.
