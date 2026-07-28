program ClienteRemoto;

{ O cliente do sample GatewaySeguro: um TPipeClient em ptTls que apresenta um
  certificado ao gateway e conversa com um servico que nao sabe o que e' TLS,
  do outro lado da maquina.

  O que ele existe para mostrar nao e' o caminho feliz — e' a metade que
  RECUSA. Escolha a identidade no segundo parametro:

    cli         cliente legitimo (CN=pdv-loja-001). Deve entrar.
    caixa       outro cliente legitimo (CN=caixa-02). Deve entrar, e o servico
                local deve carimbar ESTE nome nas respostas dele — rode os dois
                ao mesmo tempo; cruzamento de identidade e' o pior bug possivel
                num gateway.
    rogue       certificado bem formado, de uma CA que o gateway nao conhece.
                Deve ser recusado NO HANDSHAKE.
    selfsigned  certificado auto-assinado. Tambem recusado, e o veredito do
                backend deve ser DISTINTO do caso rogue.
    nenhum      nao apresenta certificado nenhum. Recusado.

  Em qualquer um dos tres ultimos casos o ServicoLocal nao pode registrar
  absolutamente nada: e' a prova de que nada vazou para tras do gateway.

  Os DOIS backends recusam, mas em momentos diferentes, e o sample mostra isso
  em vez de esconder: no OpenSSL a recusa acontece dentro do proprio handshake e
  o Connect falha; no SChannel a cadeia do cliente e' conferida DEPOIS do
  handshake, entao o Connect pode concluir e a conexao cair logo em seguida
  (OnDisconnected, sem nenhuma resposta). Os dois vereditos estao certos — o que
  nao pode acontecer, e nao acontece, e' o cliente indevido falar com o servico
  local.

  DUAS CAMADAS DE "CONECTADO": com o certificado certo, este cliente pode
  conectar e autenticar com sucesso e MESMO ASSIM nao ter servico, porque o
  ServicoLocal esta fora do ar. Nesse caso o gateway responde
  RECUSADO|<motivo> antes de desligar — handshake TLS concluido nao e' o mesmo
  que sessao util. Teste: suba o gateway sem o servico local.

  Credenciais: PKI de TESTE versionada em tests/pki (ver o LEIA-ME de la — NAO
  tem valor de seguranca).

  Validacao do servidor: LIGADA no backend OpenSSL, onde CaFile basta para
  ancorar a CA de teste. No SChannel ela e' desligada, e SO por la': o cliente
  Windows valida contra o trust store do SO e ignora CaFile, entao com uma PKI
  de teste nao instalada na maquina nao ha como validar sem desligar. Sem
  validar o servidor, o cliente cifra o trafego mas nao sabe com quem fala, e a
  sessao fica MITM-avel. Em producao: instale a CA no trust store do Windows,
  ou use o backend OpenSSL com CaFile.

  Uso: ClienteRemoto [endereco] [identidade]
       (padroes: 127.0.0.1:5000, cli)
  Digite texto e Enter para mandar; "sair" (ou linha vazia) encerra.

  Compila nos dois mundos a partir do MESMO fonte:
    FPC (Windows): lazbuild ClienteRemoto.lpi
    FPC (Linux):   fpc -MDelphi -Sh -Fu../../src -Fi../../src -dPIPES_OPENSSL \
                     ClienteRemoto.dpr
                   (SChannel nao existe fora do Windows; -dPIPES_OPENSSL e'
                   obrigatorio para ligar o backend TLS no Linux)
    Delphi:        abrir ClienteRemoto.dproj no IDE }

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
  Pipes.Client,
  Gateway.Protocolo in 'Gateway.Protocolo.pas';

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
  TClienteRemotoApp = class
  private
    FClient: TPipeClient;
    FConsoleLock: TCriticalSection;
    procedure Log(const AMsg: string);
    procedure AplicaIdentidade(const APki, AIdentidade: string);
    procedure OnMsg(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure OnConn(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnDisc(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnErr(Sender: TObject; AConnId: TPipeConnectionId;
      const AError: string);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run(const AAddress, AIdentidade: string);
  end;

constructor TClienteRemotoApp.Create;
begin
  inherited Create;
  FConsoleLock := TCriticalSection.Create;
end;

destructor TClienteRemotoApp.Destroy;
begin
  FClient.Free; // Disconnect no destructor
  FConsoleLock.Free;
  inherited;
end;

procedure TClienteRemotoApp.Log(const AMsg: string);
begin
  FConsoleLock.Enter;
  try
    Writeln(AMsg);
  finally
    FConsoleLock.Leave;
  end;
end;

{ Um so' lugar decide qual certificado vai ser apresentado. Os dois backends
  leem formatos diferentes: SChannel um PFX (cert+chave juntos), OpenSSL um par
  de PEM. }
procedure TClienteRemotoApp.AplicaIdentidade(const APki, AIdentidade: string);
var
  LBase: string;
begin
  if SameText(AIdentidade, 'nenhum') then
  begin
    // Sem CertFile o cliente nao apresenta certificado nenhum. Com CaFile
    // ligado no gateway, isso e' recusa certa — e e' o teste que prova que o
    // mTLS nao e' decorativo.
    Log('identidade: NENHUMA (sem certificado) - deve ser recusado');
  end
  else
  begin
    if SameText(AIdentidade, 'cli') then
      LBase := 'cli'
    else if SameText(AIdentidade, 'caixa') then
      LBase := 'caixa'
    else if SameText(AIdentidade, 'rogue') then
      LBase := 'rogue'
    else if SameText(AIdentidade, 'selfsigned') then
      LBase := 'selfsigned'
    else
      raise Exception.Create('identidade desconhecida: "' + AIdentidade +
        '" (use cli | caixa | rogue | selfsigned | nenhum)');
    {$IFDEF PIPES_SCHANNEL}
    FClient.TlsOptions.CertFile := APki + LBase + '.pfx';
    FClient.TlsOptions.CertPassword := 'pipestest';
    {$ELSE}
    FClient.TlsOptions.CertFile := APki + LBase + '_cert.pem';
    FClient.TlsOptions.KeyFile := APki + LBase + '_key.pem';
    {$ENDIF}
    Log('identidade: ' + LBase);
  end;

  {$IFDEF PIPES_SCHANNEL}
  // SO no SChannel: aqui o cliente valida contra o trust store do Windows e
  // ignora CaFile, entao com a PKI de teste nao ha como validar sem desligar.
  // NUNCA em producao — ver o comentario no topo do arquivo.
  FClient.TlsOptions.SkipServerVerification := True;
  {$ELSE}
  // No OpenSSL a validacao fica LIGADA: CaFile ancora a CA de teste e o
  // certificado do gateway (CN=localhost, SAN localhost + 127.0.0.1) valida de
  // verdade. E' o comportamento que um sample deve demonstrar.
  FClient.TlsOptions.CaFile := APki + 'ca_cert.pem';
  {$ENDIF}
end;

procedure TClienteRemotoApp.OnMsg(Sender: TObject; AConnId: TPipeConnectionId;
  const AData: TBytes);
var
  LMotivo: string;
begin
  // A unica mensagem que vem do GATEWAY (e nao do servico local) e' a recusa
  // de aplicacao. Tudo o mais e' resposta do servico, repassada opaca.
  if GatewayEhRecusado(AData, LMotivo) then
  begin
    Log('');
    Log('*** RECUSADO PELO GATEWAY: ' + LMotivo);
    Log('    (a sessao TLS estava valida: esta recusa e de APLICACAO. Handshake');
    Log('     concluido nao e o mesmo que ter servico do outro lado.)');
    Exit;
  end;
  Log('servico local respondeu: ' + PipeUtf8Decode(AData));
end;

procedure TClienteRemotoApp.OnConn(Sender: TObject; AConnId: TPipeConnectionId);
begin
  // Deliberadamente NAO diz "autenticado": no SChannel o gateway confere a
  // cadeia do cliente DEPOIS do handshake, entao chegar aqui com um certificado
  // invalido e' possivel — a conexao simplesmente cai a seguir, sem nenhuma
  // resposta. Um sample que anunciasse "autenticado" aqui estaria ensinando a
  // confiar no evento errado; a prova de que a sessao serve para alguma coisa
  // e' a primeira resposta do servico local.
  Log('sessao TLS aberta com o gateway.');
end;

procedure TClienteRemotoApp.OnDisc(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log('desconectado do gateway.');
end;

procedure TClienteRemotoApp.OnErr(Sender: TObject; AConnId: TPipeConnectionId;
  const AError: string);
begin
  Log('erro: ' + AError);
end;

procedure TClienteRemotoApp.Run(const AAddress, AIdentidade: string);
var
  LLinha, LPki: string;
begin
  LPki := PkiDir;
  if LPki = '' then
    raise Exception.Create('tests/pki nao encontrada a partir de ' +
      ParamStr(0) + ' - este sample usa a PKI de teste versionada no repositorio');

  FClient := TPipeClient.Create(AAddress, ptTls);
  AplicaIdentidade(LPki, AIdentidade);
  FClient.OnMessage := OnMsg;
  FClient.OnConnected := OnConn;
  FClient.OnDisconnected := OnDisc;
  FClient.OnError := OnErr;
  try
    FClient.Connect(5000); // re-tenta ate 5 s (cobre gateway ainda subindo)
  except
    on E: EPipeError do
    begin
      // Com identidade rogue/selfsigned/nenhum, o caminho esperado e' este: a
      // recusa acontece no HANDSHAKE, antes de qualquer byte de aplicacao — e o
      // ServicoLocal nao registra nada, porque o gateway nem chegou a abrir uma
      // conexao local.
      Log('nao conectou: ' + E.Message);
      Log('(com certificado invalido ou ausente, e o que deve acontecer)');
      Exit;
    end;
  end;

  Log('backend TLS: ' + PipeTlsBackendInfo);
  Log('conectado a "' + AAddress + '". Digite texto ou "sair".');
  while True do
  begin
    Readln(LLinha);
    if (LLinha = '') or SameText(LLinha, 'sair') then
      Break;
    try
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
  App: TClienteRemotoApp;
  Addr, Identidade: string;
begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  if ParamCount >= 1 then
    Addr := ParamStr(1)
  else
    Addr := '127.0.0.1:5000';
  if ParamCount >= 2 then
    Identidade := ParamStr(2)
  else
    Identidade := 'cli';
  App := TClienteRemotoApp.Create;
  try
    App.Run(Addr, Identidade);
  finally
    App.Free;
  end;
end.
