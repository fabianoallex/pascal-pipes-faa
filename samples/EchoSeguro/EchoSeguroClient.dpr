program EchoSeguroClient;

{ Cliente de eco console sobre ptTls com mTLS: apresenta o certificado de
  cliente da PKI de tests/pki e le linhas do teclado:
    texto      -> SendText (fire-and-forget); o eco assincrono chega via
                  OnMessage, numa thread do pool
    ?texto     -> RequestText (RPC sincrono com timeout de 5 s); o reply chega
                  como retorno da chamada, correlacionado pela lib
    sair       -> encerra (linha vazia tambem)

  Credenciais: ver EchoSeguroServer.dpr e o LEIA-ME de tests/pki.

  Validacao do servidor: LIGADA no backend OpenSSL, onde CaFile basta para
  ancorar a CA de teste. No SChannel ela e' desligada, e SO por la': o cliente
  Windows valida contra o trust store do SO e ignora CaFile, entao com uma PKI
  de teste nao instalada na maquina nao ha como validar sem desligar.

  Isso importa como exemplo: sem validar o servidor o cliente cifra o trafego
  mas nao sabe com quem fala, e a sessao fica MITM-avel. Um sample que
  desligasse a validacao nos DOIS backends ensinaria o habito errado onde ele
  nem e' necessario. Em producao: instale a CA no trust store do Windows, ou
  use o backend OpenSSL com CaFile.

  Compila nos dois mundos a partir do MESMO fonte:
    FPC (Windows): lazbuild EchoSeguroClient.lpi
    FPC (Linux):   fpc -MDelphi -Sh -Fu../../src -Fi../../src -dPIPES_OPENSSL \
                     EchoSeguroClient.dpr
                   (SChannel nao existe fora do Windows; -dPIPES_OPENSSL e'
                   obrigatorio para ligar o backend TLS no Linux)
    Delphi:        abrir EchoSeguroClient.dproj no IDE

  Uso: EchoSeguroClient [endereco]   (padrao 127.0.0.1:5000) }

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
  Pipes.Client;

// Procura 'tests/pki' subindo a partir de ADir. '' se nao achar. Mesma logica
// de tests/Integration/Pipes.TlsTests.pas.
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
  TEchoSeguroClientApp = class
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
    procedure Run(const AAddress: string);
  end;

constructor TEchoSeguroClientApp.Create;
begin
  inherited Create;
  FConsoleLock := TCriticalSection.Create;
end;

destructor TEchoSeguroClientApp.Destroy;
begin
  FClient.Free; // Disconnect no destructor
  FConsoleLock.Free;
  inherited;
end;

procedure TEchoSeguroClientApp.Log(const AMsg: string);
begin
  FConsoleLock.Enter;
  try
    Writeln(AMsg);
  finally
    FConsoleLock.Leave;
  end;
end;

procedure TEchoSeguroClientApp.OnMsg(Sender: TObject; AConnId: TPipeConnectionId;
  const AData: TBytes);
begin
  Log('eco assincrono: ' + PipeUtf8Decode(AData));
end;

procedure TEchoSeguroClientApp.OnConn(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log('conectado e autenticado via mTLS.');
end;

procedure TEchoSeguroClientApp.OnDisc(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log('desconectado do servidor.');
end;

procedure TEchoSeguroClientApp.OnErr(Sender: TObject; AConnId: TPipeConnectionId;
  const AError: string);
begin
  Log('erro: ' + AError);
end;

procedure TEchoSeguroClientApp.Run(const AAddress: string);
var
  LLinha, LReply, LPki: string;
begin
  LPki := PkiDir;
  if LPki = '' then
    raise Exception.Create('tests/pki nao encontrada a partir de ' +
      ParamStr(0) + ' - este sample usa a PKI de teste versionada no repositorio');

  FClient := TPipeClient.Create(AAddress, ptTls);
  {$IFDEF PIPES_SCHANNEL}
  FClient.TlsOptions.CertFile := LPki + 'cli.pfx';
  FClient.TlsOptions.CertPassword := 'pipestest';
  // SO no SChannel: aqui o cliente valida contra o trust store do Windows e
  // ignora CaFile, entao com a PKI de teste nao ha como validar sem desligar.
  // NUNCA em producao — ver o comentario no topo do arquivo.
  FClient.TlsOptions.SkipServerVerification := True;
  {$ELSE}
  FClient.TlsOptions.CertFile := LPki + 'cli_cert.pem';
  FClient.TlsOptions.KeyFile := LPki + 'cli_key.pem';
  // No OpenSSL a validacao fica LIGADA: CaFile ancora a CA de teste e o
  // certificado do servidor (CN=localhost, SAN localhost + 127.0.0.1) valida
  // de verdade. E' o comportamento que um sample deve demonstrar.
  FClient.TlsOptions.CaFile := LPki + 'ca_cert.pem';
  {$ENDIF}

  FClient.OnMessage := OnMsg;
  FClient.OnConnected := OnConn;
  FClient.OnDisconnected := OnDisc;
  FClient.OnError := OnErr;
  FClient.Connect(5000); // re-tenta ate 5 s (cobre servidor ainda subindo)

  Log('backend TLS: ' + PipeTlsBackendInfo);
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
  App: TEchoSeguroClientApp;
  Addr: string;
begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  if ParamCount >= 1 then
    Addr := ParamStr(1)
  else
    Addr := '127.0.0.1:5000';
  App := TEchoSeguroClientApp.Create;
  try
    App.Run(Addr);
  finally
    App.Free;
  end;
end.
