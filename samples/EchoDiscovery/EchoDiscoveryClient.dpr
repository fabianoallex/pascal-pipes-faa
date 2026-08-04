program EchoDiscoveryClient;

{ Cliente de eco console que acha o servidor por broadcast UDP em vez de
  receber o endereco digitado (ver Pipes.Discovery / README.md, secao
  "Descoberta de servidor na LAN"). Nenhum servidor novo precisa existir:
  suba o EchoServer.exe de sempre com "discover" no final da linha de comando
  (so' funciona com tcp/tls - ptLocal nao tem porta de rede para anunciar) e
  este cliente encontra sozinho.

  Mesma interacao do EchoClient (texto = SendText assincrono; ?texto =
  RequestText sincrono; sair encerra), precedida da sonda de descoberta e de
  um log de qual servidor foi encontrado - e' o que torna "sem IP digitado"
  visivel.

  Roteiro de 1 minuto (ptTcp, sem PKI):
    1) EchoServer.exe *:5300 tcp discover
    2) EchoDiscoveryClient.exe
       -> "encontrado: EchoServer em <ip>:5300 (ptTcp)" e conecta sozinho
    3) troque mensagens normalmente

  Roteiro com mTLS (a mesma PKI de teste do EchoSeguro/EchoServer):
    1) EchoServer.exe *:5300 tls ..\..\tests\pki mtls discover
    2) EchoDiscoveryClient.exe ..\..\tests\pki cli
       -> a descoberta acha o CANDIDATO (ip:porta); quem autentica e' o
          handshake TLS que vem a seguir, nao a descoberta (ver
          docs/ARQUITETURA.md, secao 16.4)

  Compila nos dois mundos a partir do MESMO fonte:
    FPC:    fpc -MDelphi -Sh -Fu..\..\src EchoDiscoveryClient.dpr   (ou lazbuild EchoDiscoveryClient.lpi)
    Delphi: abrir EchoDiscoveryClient.dproj no IDE

  Uso: EchoDiscoveryClient [dir-pki [nome-certificado-cliente]]

  <dir-pki> so' e' preciso se o servidor encontrado anunciar ptTls (o cliente
  nao escolhe o transporte - quem decide e' o servidor, via responder). Sem
  PKI e servidor ptTls encontrado, o sample avisa e sai, em vez de tentar
  conectar sem CaFile. <nome-certificado-cliente> e' so' para mTLS, igual ao
  EchoClient ('cli' funciona com a PKI de tests/pki).

  Alcance e' a sub-rede local (broadcast nao atravessa roteador/VPN) e a
  janela de espera e' fixa em 1s - suficiente na mesma maquina/LAN; ver
  PipeDiscoverServers em Pipes.Discovery.pas para trocar porta/token/timeout. }

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
  Pipes.Client,
  Pipes.Discovery;

type
  { Callbacks sao 'of object': o estado do sample vive nesta classe. }
  TEchoDiscoveryClientApp = class
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
    procedure Run(const APkiDir, ACliCert: string);
  end;

constructor TEchoDiscoveryClientApp.Create;
begin
  inherited Create;
  FConsoleLock := TCriticalSection.Create;
end;

destructor TEchoDiscoveryClientApp.Destroy;
begin
  FClient.Free; // Disconnect no destructor; nil-safe se Run saiu antes de criar
  FConsoleLock.Free;
  inherited;
end;

procedure TEchoDiscoveryClientApp.Log(const AMsg: string);
begin
  FConsoleLock.Enter;
  try
    Writeln(AMsg);
  finally
    FConsoleLock.Leave;
  end;
end;

procedure TEchoDiscoveryClientApp.OnMsg(Sender: TObject;
  AConnId: TPipeConnectionId; const AData: TBytes);
begin
  Log('eco assincrono: ' + PipeUtf8Decode(AData));
end;

procedure TEchoDiscoveryClientApp.OnConn(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  Log('conectado.');
end;

procedure TEchoDiscoveryClientApp.OnDisc(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  Log('desconectado do servidor.');
end;

procedure TEchoDiscoveryClientApp.OnErr(Sender: TObject;
  AConnId: TPipeConnectionId; const AError: string);
begin
  Log('erro: ' + AError);
end;

function NomeTransporte(ATransport: TPipeTransport): string;
begin
  case ATransport of
    ptTcp: Result := 'ptTcp';
    ptTls: Result := 'ptTls';
  else
    Result := 'ptLocal';
  end;
end;

procedure TEchoDiscoveryClientApp.Run(const APkiDir, ACliCert: string);
var
  LEncontrados: TArray<TPipeServerInfo>;
  LInfo: TPipeServerInfo;
  LDir, LLinha, LReply: string;
begin
  Log('procurando servidor na rede local (1s, broadcast UDP)...');
  LEncontrados := PipeDiscoverServers(1000);
  if Length(LEncontrados) = 0 then
  begin
    Log('nenhum servidor respondeu. Ele esta rodando com "discover" no ' +
      'final da linha de comando? (Ex.: EchoServer *:5300 tcp discover)');
    Exit;
  end;
  LInfo := LEncontrados[0];
  Log(Format('encontrado: "%s" em %s (%s)',
    [LInfo.Name, LInfo.Address, NomeTransporte(LInfo.Transport)]));
  if Length(LEncontrados) > 1 then
    // Mais de um responder na sub-rede (ou o mesmo host reenviando enquanto a
    // janela ainda estava aberta) - PipeDiscoverServers ja' desduplica; o que
    // sobra aqui e' mais de UM servidor de verdade.
    Log(Format('(+ %d outro(s) respondeu(ram); usando o primeiro)',
      [Length(LEncontrados) - 1]));

  FClient := TPipeClient.Create(LInfo.Address);
  FClient.Transport := LInfo.Transport;
  if LInfo.Transport = ptTls then
  begin
    if APkiDir = '' then
    begin
      Log('o servidor encontrado usa ptTls, mas nenhum dir-pki foi passado.');
      Log('Uso: EchoDiscoveryClient <dir-pki> [nome-certificado-cliente]');
      Exit;
    end;
    LDir := IncludeTrailingPathDelimiter(APkiDir);
    // CA que assina o servidor. A descoberta so' achou o CANDIDATO; quem
    // autentica de verdade e' este handshake, nao PipeDiscoverServers.
    FClient.TlsOptions.CaFile := LDir + 'ca_cert.pem';
    if ACliCert <> '' then
    begin
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
  FClient.Connect(5000);
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
  App: TEchoDiscoveryClientApp;
  PkiDir, CliCert: string;
begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  PkiDir := '';
  CliCert := '';
  if ParamCount >= 1 then
    PkiDir := ParamStr(1);
  if ParamCount >= 2 then
    CliCert := ParamStr(2);
  App := TEchoDiscoveryClientApp.Create;
  try
    App.Run(PkiDir, CliCert);
  finally
    App.Free;
  end;
end.
