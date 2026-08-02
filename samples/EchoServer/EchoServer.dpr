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

  Uso: EchoServer [endereco] [tcp|tls [dir-pki] [mtls]]

    EchoServer                         ptLocal em 'pipes_faa_echo' (padrao)
    EchoServer meu_pipe                ptLocal em 'meu_pipe'
    EchoServer *:5300 tcp              ptTcp em todas as interfaces, porta 5300
    EchoServer *:5300 tls ..\..\tools\pki-android
    EchoServer *:5300 tls <dir> mtls   exige certificado do cliente

  Os parametros a partir do segundo sao opcionais e mantem o comportamento
  antigo intacto: sem eles, ptLocal como sempre. Existem para o sample
  EchoAndroid, que so' fala ptTcp/ptTls — um celular nao alcanca Named Pipe nem
  Unix Domain Socket. '*' e' atalho de '0.0.0.0'; '127.0.0.1:5300' escutaria SO'
  na propria maquina e o celular nao chegaria.

  O modo tls le a PKI do diretorio dado. Diferente do sample EchoSeguro, que usa
  a PKI de teste versionada em tests/pki, aqui o diretorio e' parametro — a PKI
  de teste tem SAN 'DNS:localhost, IP:127.0.0.1' e NAO serve para um celular
  discando o IP da LAN. Gere a sua com tools/gerar-pki.sh -a "IP:<seu-ip>".

  Quais arquivos ele procura depende do backend compilado, nao de escolha do
  sample: Schannel (padrao no Windows) le srv.pfx + a senha de senha-pfx.txt;
  OpenSSL le srv_cert.pem + srv_key.pem. Ambos sao gerados pelo gerar-pki.sh. }

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
    procedure Run(const AAddress: string; ATransport: TPipeTransport;
      const APkiDir: string; AMtls: Boolean);
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

// Le a senha do PFX gravada pelo gerar-pki.sh. Ausente = PFX sem senha.
function LeSenhaPfx(const ADir: string): string;
var
  LArq: TStringList;
begin
  Result := '';
  if not FileExists(ADir + 'senha-pfx.txt') then
    Exit;
  LArq := TStringList.Create;
  try
    LArq.LoadFromFile(ADir + 'senha-pfx.txt');
    if LArq.Count > 0 then
      Result := Trim(LArq[0]);
  finally
    LArq.Free;
  end;
end;

procedure TEchoServerApp.Run(const AAddress: string;
  ATransport: TPipeTransport; const APkiDir: string; AMtls: Boolean);
var
  LDir, LFalta: string;
begin
  FServer := TNamedPipeServer.Create(AAddress);
  FServer.Transport := ATransport;
  if ATransport in [ptTcp, ptTls] then
    // Rede movel/Wi-Fi que dorme derruba conexao ociosa em silencio; sem isto o
    // servidor acumularia conexao zumbi de celular que saiu de alcance.
    FServer.HeartbeatIntervalMs := 15000;
  if ATransport = ptTls then
  begin
    LDir := IncludeTrailingPathDelimiter(APkiDir);
    // O backend e' escolhido em tempo de compilacao; o sample so' aponta os
    // arquivos que aquele backend sabe ler.
    {$IFDEF PIPES_SCHANNEL}
    FServer.TlsOptions.CertFile := LDir + 'srv.pfx';
    FServer.TlsOptions.CertPassword := LeSenhaPfx(LDir);
    LFalta := LDir + 'srv.pfx';
    {$ELSE}
    FServer.TlsOptions.CertFile := LDir + 'srv_cert.pem';
    FServer.TlsOptions.KeyFile := LDir + 'srv_key.pem';
    LFalta := LDir + 'srv_cert.pem';
    {$ENDIF}
    if not FileExists(LFalta) then
      raise Exception.Create('credencial de servidor nao encontrada: ' + LFalta +
        ' (gere a PKI com tools/gerar-pki.sh)');
    if AMtls then
    begin
      // CaFile no SERVIDOR liga mTLS: cliente sem certificado desta CA e'
      // recusado antes de OnClientConnected disparar.
      FServer.TlsOptions.CaFile := LDir + 'ca_cert.pem';
      if not FileExists(FServer.TlsOptions.CaFile) then
        raise Exception.Create('mtls pedido mas falta ' +
          FServer.TlsOptions.CaFile);
    end;
  end;
  FServer.OnMessage := OnMsg;
  FServer.OnRequest := OnReq;
  FServer.OnClientConnected := OnConn;
  FServer.OnClientDisconnected := OnDisc;
  FServer.OnError := OnErr;
  FServer.Listen; // nao-blocante: acceptor + readers em threads proprias
  case ATransport of
    ptTcp: Log('escutando em "' + AAddress + '" (ptTcp) - Enter encerra');
    ptTls:
      if AMtls then
        Log('escutando em "' + AAddress + '" (ptTls + mTLS) - Enter encerra')
      else
        Log('escutando em "' + AAddress + '" (ptTls) - Enter encerra');
  else
    Log('escutando em "' + AAddress + '" (ptLocal) - Enter encerra');
  end;
  Readln;
  FServer.Stop; // sincrono: join de tudo, drena callbacks em voo
  Log('encerrado.');
end;

var
  App: TEchoServerApp;
  Address, PkiDir: string;
  Transport: TPipeTransport;
  Mtls: Boolean;
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
  Mtls := False;
  if ParamCount >= 2 then
  begin
    if SameText(ParamStr(2), 'tcp') then
      Transport := ptTcp
    else if SameText(ParamStr(2), 'tls') then
    begin
      Transport := ptTls;
      if ParamCount < 3 then
      begin
        Writeln('modo tls exige o diretorio da PKI. ' +
          'Ex.: EchoServer *:5300 tls ..\..\tools\pki-android');
        Halt(2);
      end;
      PkiDir := ParamStr(3);
      Mtls := (ParamCount >= 4) and SameText(ParamStr(4), 'mtls');
    end;
  end;
  App := TEchoServerApp.Create;
  try
    App.Run(Address, Transport, PkiDir, Mtls);
  finally
    App.Free;
  end;
end.
