program EchoSeguroServer;

{ Servidor de eco console sobre ptTls com mTLS: exige certificado de cliente
  valido pela CA de tests/pki e cifra todo o trafego. Mesmo comportamento de
  eco do EchoServer (prefixo 'eco:', SendText/Request), mas sobre a rede
  (host:porta) em vez de named pipe local.

  Credenciais: PKI de TESTE versionada em tests/pki (ver o LEIA-ME de la — NAO
  tem valor de seguranca, nunca reaproveitar fora da suite/deste sample).
  Windows/Schannel le um PFX (srv.pfx); Linux/OpenSSL le PEM (srv_cert.pem +
  srv_key.pem). CaFile liga o mTLS: sem certificado de cliente valido pela
  mesma CA, a conexao e' recusada ANTES do OnClientConnected disparar — se um
  cliente sem certificado (ou TPipeClient comum) conseguir conectar, o mTLS
  esta decorativo.

  Compila nos dois mundos a partir do MESMO fonte:
    FPC (Windows): lazbuild EchoSeguroServer.lpi
    FPC (Linux):   fpc -MDelphi -Sh -Fu../../src -Fi../../src \
                     EchoSeguroServer.dpr
                   (o TLS e' OpenSSL fora do Windows; desde a 0.4.0 nao
                   precisa mais de -dPIPES_OPENSSL)
    Delphi:        abrir EchoSeguroServer.dproj no IDE

  Uso: EchoSeguroServer [endereco]   (padrao 0.0.0.0:5000) }

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
  Pipes.Base,
  Pipes.Server;

// Procura 'tests/pki' subindo a partir de ADir. '' se nao achar. Mesma logica
// de tests/Integration/Pipes.TlsTests.pas: o executavel pode acabar em pastas
// diferentes (raiz do sample ou Win64/Debug, no build Delphi).
function ProcuraPkiAcimaDe(const ADir: string): string;
var
  LDir: string;
  I: Integer;
begin
  Result := '';
  LDir := IncludeTrailingPathDelimiter(ADir);
  for I := 0 to 6 do
  begin
    if FileExists(LDir + 'tests' + PathDelim + 'pki' + PathDelim +
         'ca_cert.pem') then
      Exit(LDir + 'tests' + PathDelim + 'pki' + PathDelim);
    LDir := LDir + '..' + PathDelim;
  end;
end;

function PkiDir: string;
begin
  Result := ProcuraPkiAcimaDe(ExtractFilePath(ParamStr(0)));
  if Result = '' then
    Result := ProcuraPkiAcimaDe(GetCurrentDir);
end;

type
  { Callbacks sao 'of object': o estado do sample vive nesta classe. }
  TEchoSeguroServerApp = class
  private
    FServer: TPipeServer;
    FConsoleLock: TCriticalSection;
    FBackendLogado: Boolean;
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
    procedure Run(const AAddress: string);
  end;

constructor TEchoSeguroServerApp.Create;
begin
  inherited Create;
  FConsoleLock := TCriticalSection.Create;
end;

destructor TEchoSeguroServerApp.Destroy;
begin
  FServer.Free; // Stop no destructor
  FConsoleLock.Free;
  inherited;
end;

procedure TEchoSeguroServerApp.Log(const AMsg: string);
begin
  FConsoleLock.Enter;
  try
    Writeln(AMsg);
  finally
    FConsoleLock.Leave;
  end;
end;

procedure TEchoSeguroServerApp.OnMsg(Sender: TObject; AConnId: TPipeConnectionId;
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

procedure TEchoSeguroServerApp.OnReq(Sender: TObject; AConnId: TPipeConnectionId;
  const ARequest: TBytes; out AReply: TBytes);
var
  LTexto: string;
begin
  LTexto := PipeUtf8Decode(ARequest);
  Log(Format('[conn %d] request: %s', [AConnId, LTexto]));
  AReply := PipeUtf8Encode('eco:' + LTexto); // a lib envia o reply com o corrId certo
end;

procedure TEchoSeguroServerApp.OnConn(Sender: TObject; AConnId: TPipeConnectionId);
begin
  // PipeTlsBackendInfo so' fica preenchido depois do PRIMEIRO handshake (ver o
  // comentario em Pipes.Types) — vazio logo apos o Listen, que e' nao-blocante
  // e nao negocia nada sozinho. Aqui, no primeiro cliente autenticado, ja da'.
  if not FBackendLogado then
  begin
    FBackendLogado := True;
    Log('backend TLS: ' + PipeTlsBackendInfo);
  end;
  // So dispara DEPOIS do handshake mTLS completo: e' o sinal de que o cliente
  // apresentou um certificado valido pela CaFile configurada.
  Log(Format('[conn %d] conectou e autenticou via mTLS (%d cliente(s))',
    [AConnId, FServer.ClientCount]));
end;

procedure TEchoSeguroServerApp.OnDisc(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log(Format('[conn %d] desconectou (%d cliente(s))', [AConnId, FServer.ClientCount]));
end;

procedure TEchoSeguroServerApp.OnErr(Sender: TObject; AConnId: TPipeConnectionId;
  const AError: string);
begin
  // Onde cai um cliente sem certificado (ou de outra CA): o handshake e'
  // recusado ANTES de OnClientConnected. Se isso nunca aparecer contra um
  // cliente indevido, o mTLS esta decorativo.
  Log(Format('[conn %d] erro (handshake/mTLS recusado?): %s', [AConnId, AError]));
end;

procedure TEchoSeguroServerApp.Run(const AAddress: string);
var
  LPki: string;
begin
  LPki := PkiDir;
  if LPki = '' then
    raise Exception.Create('tests/pki nao encontrada a partir de ' +
      ParamStr(0) + ' - este sample usa a PKI de teste versionada no repositorio');

  FServer := TPipeServer.Create(AAddress, ptTls);
  // Os dois backends leem formatos diferentes: SChannel um PFX (cert+chave
  // juntos), OpenSSL um par de PEM.
  {$IFDEF PIPES_SCHANNEL}
  FServer.TlsOptions.CertFile := LPki + 'srv.pfx';
  FServer.TlsOptions.CertPassword := 'pipestest';
  {$ELSE}
  FServer.TlsOptions.CertFile := LPki + 'srv_cert.pem';
  FServer.TlsOptions.KeyFile := LPki + 'srv_key.pem';
  {$ENDIF}
  FServer.TlsOptions.CaFile := LPki + 'ca_cert.pem'; // LIGA o mTLS

  FServer.OnMessage := OnMsg;
  FServer.OnRequest := OnReq;
  FServer.OnClientConnected := OnConn;
  FServer.OnClientDisconnected := OnDisc;
  FServer.OnError := OnErr;
  FServer.Listen; // nao-blocante: acceptor + readers em threads proprias

  Log('escutando (mTLS) em "' + AAddress + '" - Enter encerra');
  Readln;
  FServer.Stop; // sincrono: join de tudo, drena callbacks em voo
  Log('encerrado.');
end;

var
  App: TEchoSeguroServerApp;
  Addr: string;
begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  if ParamCount >= 1 then
    Addr := ParamStr(1)
  else
    Addr := '0.0.0.0:5000';
  App := TEchoSeguroServerApp.Create;
  try
    App.Run(Addr);
  finally
    App.Free;
  end;
end.
