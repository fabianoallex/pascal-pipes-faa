unit Pipes.TlsTests;

{$I pipes.inc}

{ Testes de integracao do ptTls pela API PUBLICA (TPipeServer/TPipeClient) —
  o caminho que o usuario da biblioteca realmente escreve.

  Metade destes testes e' de RECUSA, e e' a metade que importa. Uma bateria que
  so' verificasse "cliente autorizado conecta" passaria com a autenticacao
  inteiramente quebrada: foi assim que um bypass de mTLS no SChannel sobreviveu
  a uma rodada de verificacao neste projeto (ver commit 0b11f97). O caso do
  cliente com certificado de outra CA e' o guarda dessa regressao.

  As credenciais vem de tests/pki, versionada de proposito (ver o LEIA-ME de
  la'). Sem backend TLS no build, o fixture inteiro some — daí o include de
  pipes.inc no topo, para enxergar PIPES_TLS.

  Versao DUnitX/Delphi; espelha a versao FPCUnit em tests/Integration/fpc. }

interface

{$IFDEF PIPES_TLS}
uses
  DUnitX.TestFramework,
  SysUtils,
  Classes,
  SyncObjs,
  Pipes.Types,
  Pipes.Base,
  Pipes.Server,
  Pipes.Client;

type
  { Servidor + cliente ptTls prontos para um round-trip, com os observaveis que
    os testes conferem (eco recebido, cliente autenticado, erro do servidor). }
  TTlsHarness = class
  private
    FServer: TPipeServer;
    FClient: TPipeClient;
    FEcho: TEvent;
    FConnected: TEvent;
    FLastConnId: TPipeConnectionId;
    // Quando True, o handler de queda do CLIENTE desliga AutoReconnect — e' o
    // padrao "recusa permanente" do sample ChatSeguro.
    FDesligarReconexaoAoCair: Boolean;
    // Preenchidos DE DENTRO de OnClientConnected (ver o handler).
    FIdentityFromHandler: TPipePeerIdentity;
    FIdentityNoHandler: Boolean;
    FErroEvt: TEvent;   // sinalizado quando o servidor reporta um erro de conexao
    FRecebido: string;
    FErroServidor: string;
    FCliConnCount: Integer; // atomico: quantas vezes o CLIENTE conectou
    FCliDiscCount: Integer; // atomico: quantas vezes o CLIENTE desconectou
    procedure OnServerMsg(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure OnClientMsg(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure OnClientConnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnServerError(Sender: TObject; AConnId: TPipeConnectionId;
      const AMsg: string);
    // Lado CLIENTE (distinto de OnClientConnected, que e' o servidor
    // reconhecendo o cliente): usado so' pelo teste de AutoReconnect, para
    // contar quantas vezes o proprio cliente completou um Connect/handshake.
    procedure OnClienteConectou(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnClienteDesconectou(Sender: TObject; AConnId: TPipeConnectionId);
  public
    constructor Create(const AAddress: string);
    destructor Destroy; override;
    property Server: TPipeServer read FServer;
    property Client: TPipeClient read FClient;
    property LastConnId: TPipeConnectionId read FLastConnId;
    property DesligarReconexaoAoCair: Boolean
      read FDesligarReconexaoAoCair write FDesligarReconexaoAoCair;
    function CliConnCount: Integer;
    function CliDiscCount: Integer;
    property IdentityFromHandler: TPipePeerIdentity read FIdentityFromHandler;
    property IdentityNoHandler: Boolean read FIdentityNoHandler;
    /// Sobe o servidor. ACaFile <> '' liga mTLS.
    procedure Listen(const ACaFile: string);
    /// Conecta o cliente; ACliCert <> '' apresenta certificado (mTLS).
    /// Devolve False (sem levantar) se a conexao foi recusada.
    function TryConnect(const ACliCert: string; out AErro: string): Boolean;
    /// Conecta com o DEFAULT de validacao (SkipServerVerification=False): o
    /// cliente valida a cadeia do servidor. Diferente de TryConnect, que a
    /// desliga. False (sem levantar) se recusada. Sem certificado de cliente.
    function TryConnectValidandoServidor(out AErro: string): Boolean;
    /// True se o servidor tratou o cliente como AUTENTICADO — OnClientConnected
    /// so dispara depois do handshake, entao e' o sinal de que ele entrou.
    function ClienteAutenticado(ATimeoutMs: Integer): Boolean;
    /// True se o servidor reportou um erro de conexao no prazo (OnError). E' o
    /// sinal POSITIVO de que o servidor desistiu sozinho — sem ele, um teste de
    /// timeout so' confirmaria a ausencia de autenticacao, que passaria mesmo
    /// com a reader thread presa para sempre.
    function EsperaErroServidor(ATimeoutMs: Integer): Boolean;
    /// Round-trip completo (eco). False se nao voltou no prazo.
    function Eco(const ATexto: string; ATimeoutMs: Integer): Boolean;
    /// True se o cliente completou Connect/handshake AVezes vezes no prazo
    /// (contador cumulativo, nao reseta). Usado pelo teste de AutoReconnect.
    function EsperaClienteConectou(AVezes: Integer; ATimeoutMs: Integer): Boolean;
    /// Analogo para OnDisconnected do cliente.
    function EsperaClienteDesconectou(AVezes: Integer; ATimeoutMs: Integer): Boolean;
  end;

  [TestFixture]
  TPipeTlsTests = class
  private
    FAddr: string;
    FHarness: TTlsHarness;
    procedure DoListenSemCredenciais;
    procedure DoTrocaCertComServidorAtivo;
  public
    [Setup] procedure SetUp;
    [TearDown] procedure TearDown;
  published
    // --- caminho feliz ---
    [Test] procedure Tls_RoundTripCifrado;
    [Test] procedure Mtls_ClienteComCertDaCa_Conecta;
    // --- reconexao ---
    [Test] procedure Mtls_AutoReconnect_RefazHandshakeAposQueda;
    // --- validacao do servidor pelo cliente (default seguro) ---
    [Test] procedure Tls_ClienteValidaServidorPorPadrao_Recusa;
    // --- recusa (o que de fato prova que ha autenticacao) ---
    [Test] procedure Mtls_ClienteSemCert_Recusado;
    [Test] procedure Mtls_ClienteDeOutraCa_Recusado;
    [Test] procedure Mtls_ClienteAutoAssinado_Recusado;
    [Test] procedure Mtls_ClienteDeCaGemea_Recusado;
    [Test] procedure Handshake_ClienteMudo_EstouraNoPrazo;
    // --- identidade do par autenticado ---
    [Test] procedure Mtls_IdentidadeDoCliente_TrazCnDoCertificado;
    [Test] procedure Tls_SemMtls_NaoTemIdentidade;
    [Test] procedure ClientIds_NaoListaConexaoEmHandshake;
    // --- reconexao contra recusa permanente ---
    [Test] procedure Mtls_AutoReconnectRecusado_NaoViraLacoQuente;
    [Test] procedure AutoReconnectDesligadoNoCallback_ParaDeTentar;
    [Test] procedure Mtls_MaxReconnectAttempts_AlcancaParQueAceitaEDerruba;
    // --- configuracao ---
    [Test] procedure Tls_ListenSemCredenciais_Falha;
    [Test] procedure Tls_TrocaCertComServidorAtivo_Levanta;
  end;

/// Caminho de tests/pki (procurado a partir do executavel). '' se nao achou.
function PkiDir: string;
{$ENDIF PIPES_TLS}

implementation

{$IFDEF PIPES_TLS}

uses
  Pipes.Threading;

// DUnitX recebe (condicao, mensagem) e o FPCUnit (mensagem, condicao). Estes
// wrappers adotam a ordem do FPCUnit para que os dois arquivos deste fixture
// fiquem comparaveis linha a linha — divergencia silenciosa entre eles ja seria
// um bug em si.
procedure AssertTrue(const AMsg: string; ACond: Boolean);
begin
  Assert.IsTrue(ACond, AMsg);
end;

procedure AssertFalse(const AMsg: string; ACond: Boolean);
begin
  Assert.IsFalse(ACond, AMsg);
end;

procedure AssertEquals(const AMsg, AExpected, AActual: string); overload;
begin
  Assert.AreEqual(AExpected, AActual, AMsg);
end;

procedure AssertEquals(const AMsg: string; AExpected, AActual: Integer); overload;
begin
  Assert.AreEqual(AExpected, AActual, AMsg);
end;

var
  GPkiDir: string;
  GPkiResolvido: Boolean;
  GPortSeq: Integer;

// Procura 'tests/pki' subindo a partir de ADir. '' se nao achar.
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
  if not GPkiResolvido then
  begin
    GPkiResolvido := True;
    // Duas origens porque a suite roda de lugares diferentes: do proprio
    // diretorio do executavel (tests/Integration/fpc, Win64/Debug) ou com o
    // binario fora da arvore e o cwd dentro dela — que e' o caso do build no
    // Docker, onde o -FU aponta para /tmp.
    GPkiDir := ProcuraPkiAcimaDe(ExtractFilePath(ParamStr(0)));
    if GPkiDir = '' then
      GPkiDir := ProcuraPkiAcimaDe(GetCurrentDir);
  end;
  Result := GPkiDir;
end;

function Pki(const AFile: string): string;
begin
  Result := PkiDir + AFile;
end;

// Porta unica por teste: evita colisao entre execucoes e com sockets em
// TIME_WAIT de uma rodada anterior.
function UniqueAddr: string;
begin
  Inc(GPortSeq);
  Result := '127.0.0.1:' + IntToStr(24000 + (Int64(PipeTickMs) mod 9000) +
    GPortSeq);
end;

{ TTlsHarness }

constructor TTlsHarness.Create(const AAddress: string);
begin
  inherited Create;
  FEcho := TEvent.Create(nil, True, False, '');
  FConnected := TEvent.Create(nil, True, False, '');
  FErroEvt := TEvent.Create(nil, True, False, '');
  FServer := TPipeServer.Create(AAddress, ptTls);
  FClient := TPipeClient.Create(AAddress, ptTls);
  FServer.OnMessage := OnServerMsg;
  FServer.OnClientConnected := OnClientConnected;
  FServer.OnError := OnServerError;
  FClient.OnMessage := OnClientMsg;
  FClient.OnConnected := OnClienteConectou;
  FClient.OnDisconnected := OnClienteDesconectou;
end;

destructor TTlsHarness.Destroy;
begin
  // Ordem: cliente primeiro, servidor depois — o inverso deixaria o cliente
  // tentando reconectar contra um servidor ja em Stop.
  FClient.Free;
  FServer.Free;
  FEcho.Free;
  FConnected.Free;
  FErroEvt.Free;
  inherited;
end;

procedure TTlsHarness.OnServerMsg(Sender: TObject;
  AConnId: TPipeConnectionId; const AData: TBytes);
begin
  FServer.SendBytes(AConnId, AData); // eco
end;

procedure TTlsHarness.OnClientMsg(Sender: TObject;
  AConnId: TPipeConnectionId; const AData: TBytes);
begin
  FRecebido := TEncoding.UTF8.GetString(AData);
  FEcho.SetEvent;
end;

procedure TTlsHarness.OnClientConnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  FLastConnId := AConnId;
  // Consulta AQUI de proposito, de dentro do handler: o contrato e' que a
  // conexao ja esteja publicada quando o evento dispara, entao um handler que
  // pergunte "quem chegou?" tem de conseguir a resposta na hora.
  FIdentityNoHandler :=
    FServer.TryClientIdentity(AConnId, FIdentityFromHandler);
  FConnected.SetEvent;
end;

function TTlsHarness.CliConnCount: Integer;
begin
  Result := PipeAtomicGet(FCliConnCount);
end;

function TTlsHarness.CliDiscCount: Integer;
begin
  Result := PipeAtomicGet(FCliDiscCount);
end;

procedure TTlsHarness.OnClienteConectou(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  PipeAtomicInc(FCliConnCount);
end;

procedure TTlsHarness.OnClienteDesconectou(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  PipeAtomicInc(FCliDiscCount);
  if FDesligarReconexaoAoCair then
    FClient.AutoReconnect := False; // decisao tomada DE DENTRO do callback
end;

procedure TTlsHarness.OnServerError(Sender: TObject;
  AConnId: TPipeConnectionId; const AMsg: string);
begin
  FErroServidor := AMsg;
  FErroEvt.SetEvent;
end;

// Os dois backends leem formatos diferentes: o SChannel um PFX (certificado +
// chave num arquivo), o OpenSSL um par de PEM. Escolher errado nao "degrada":
// o certificado simplesmente nao carrega — e num teste NEGATIVO isso passaria
// por sucesso, porque o cliente seria recusado de qualquer jeito, pelo motivo
// errado. Daí a selecao ser explicita aqui.
procedure AplicaCredencial(ACfg: TPipeTlsConfig; const ABase: string);
begin
  {$IFDEF PIPES_SCHANNEL}
  ACfg.CertFile := Pki(ABase + '.pfx');
  ACfg.CertPassword := 'pipestest';
  {$ELSE}
  ACfg.CertFile := Pki(ABase + '_cert.pem');
  ACfg.KeyFile := Pki(ABase + '_key.pem');
  {$ENDIF}
end;

procedure TTlsHarness.Listen(const ACaFile: string);
begin
  AplicaCredencial(FServer.TlsOptions, 'srv');
  if ACaFile <> '' then
    FServer.TlsOptions.CaFile := ACaFile;
  FServer.Listen;
end;

function TTlsHarness.TryConnect(const ACliCert: string;
  out AErro: string): Boolean;
begin
  AErro := '';
  // A PKI de teste nao esta no trust store da maquina; validar o servidor nao
  // e' o objeto destes testes (o objeto e' o servidor validar o CLIENTE).
  FClient.TlsOptions.SkipServerVerification := True;
  if ACliCert <> '' then
    AplicaCredencial(FClient.TlsOptions, ACliCert);
  try
    FClient.Connect(5000);
    Result := True;
  except
    on E: Exception do
    begin
      AErro := E.ClassName + ': ' + E.Message;
      Result := False;
    end;
  end;
end;

function TTlsHarness.TryConnectValidandoServidor(out AErro: string): Boolean;
begin
  AErro := '';
  // NAO mexe em SkipServerVerification: fica no default (False = valida). A CA
  // de teste nao esta no trust store, entao a validacao tem de RECUSAR.
  try
    FClient.Connect(5000);
    Result := True;
  except
    on E: Exception do
    begin
      AErro := E.ClassName + ': ' + E.Message;
      Result := False;
    end;
  end;
end;

function TTlsHarness.ClienteAutenticado(ATimeoutMs: Integer): Boolean;
begin
  Result := FConnected.WaitFor(ATimeoutMs) = wrSignaled;
end;

function TTlsHarness.EsperaErroServidor(ATimeoutMs: Integer): Boolean;
begin
  Result := FErroEvt.WaitFor(ATimeoutMs) = wrSignaled;
end;

function TTlsHarness.Eco(const ATexto: string; ATimeoutMs: Integer): Boolean;
begin
  FEcho.ResetEvent;
  FRecebido := '';
  try
    FClient.SendText(ATexto);
  except
    Exit(False); // conexao ja caiu: nao ha eco possivel
  end;
  Result := (FEcho.WaitFor(ATimeoutMs) = wrSignaled) and (FRecebido = ATexto);
end;

function TTlsHarness.EsperaClienteConectou(AVezes: Integer;
  ATimeoutMs: Integer): Boolean;
var
  LDeadline: UInt64;
begin
  LDeadline := PipeTickMs + ATimeoutMs;
  while (PipeAtomicGet(FCliConnCount) < AVezes) and (PipeTickMs < LDeadline) do
    Sleep(5);
  Result := PipeAtomicGet(FCliConnCount) >= AVezes;
end;

function TTlsHarness.EsperaClienteDesconectou(AVezes: Integer;
  ATimeoutMs: Integer): Boolean;
var
  LDeadline: UInt64;
begin
  LDeadline := PipeTickMs + ATimeoutMs;
  while (PipeAtomicGet(FCliDiscCount) < AVezes) and (PipeTickMs < LDeadline) do
    Sleep(5);
  Result := PipeAtomicGet(FCliDiscCount) >= AVezes;
end;

{ TPipeTlsTests }

procedure TPipeTlsTests.SetUp;
begin
  if PkiDir = '' then
    Assert.Fail('tests/pki nao encontrada a partir de ' + ParamStr(0) +
      ' — sem ela os testes de TLS nao tem credenciais');
  FAddr := UniqueAddr;
  FHarness := TTlsHarness.Create(FAddr);
end;

procedure TPipeTlsTests.TearDown;
begin
  FreeAndNil(FHarness);
end;

procedure TPipeTlsTests.Tls_RoundTripCifrado;
var
  LErro: string;
  LOk: Boolean;
begin
  FHarness.Listen(''); // sem mTLS
  LOk := FHarness.TryConnect('', LErro); // separado: LErro so' vale apos a chamada
  AssertTrue('cliente deveria conectar: ' + LErro, LOk);
  AssertTrue('servidor nao registrou o cliente como conectado',
    FHarness.ClienteAutenticado(5000));
  AssertTrue('eco cifrado nao voltou integro', FHarness.Eco('ola tls', 5000));
end;

procedure TPipeTlsTests.Mtls_ClienteComCertDaCa_Conecta;
var
  LErro: string;
  LOk: Boolean;
begin
  FHarness.Listen(Pki('ca_cert.pem')); // mTLS ligado
  LOk := FHarness.TryConnect('cli', LErro);
  AssertTrue('cliente legitimo foi recusado: ' + LErro, LOk);
  AssertTrue('servidor nao autenticou o cliente legitimo',
    FHarness.ClienteAutenticado(5000));
  AssertTrue('eco nao voltou integro', FHarness.Eco('mtls ok', 5000));
end;

procedure TPipeTlsTests.Mtls_AutoReconnect_RefazHandshakeAposQueda;
var
  LErro: string;
  LOk: Boolean;
  LDeadline: UInt64;
begin
  // TPipeTlsConfig le as credenciais UMA vez, no Connect (comentario no
  // cabecalho da classe, Pipes.Base.pas) — o risco especifico do AutoReconnect
  // e' reusar algum estado da conexao anterior em vez de refazer o handshake
  // do zero: se acontecesse, o cliente poderia reconectar sem reapresentar o
  // certificado. O guarda disso e' o proprio Eco no final: so' volta cifrado
  // se o handshake da RECONEXAO realmente aconteceu.
  FHarness.Listen(Pki('ca_cert.pem')); // mTLS ligado
  FHarness.Client.AutoReconnect := True;
  FHarness.Client.ReconnectDelayMs := 300;

  LOk := FHarness.TryConnect('cli', LErro);
  AssertTrue('primeira conexao mTLS falhou: ' + LErro, LOk);
  AssertTrue('primeira conexao nao confirmada pelo proprio cliente',
    FHarness.EsperaClienteConectou(1, 3000));
  AssertTrue('servidor nao autenticou a primeira conexao',
    FHarness.ClienteAutenticado(3000));

  FHarness.Server.Stop; // derruba o cliente
  AssertTrue('queda nao notificada ao cliente',
    FHarness.EsperaClienteDesconectou(1, 5000));

  FHarness.Server.Listen; // "restart" do servidor no mesmo endereco/credenciais
  AssertTrue('cliente nao reconectou sozinho (AutoReconnect)',
    FHarness.EsperaClienteConectou(2, 10000));

  // Contrato do AutoReconnect (igual ao teste equivalente em texto claro,
  // Pipes.EndToEndTests): um Eco pode pegar uma janela de churn entre a
  // reconexao de TCP e o handshake TLS concluir — o chamador re-tenta.
  LDeadline := PipeTickMs + 5000;
  LOk := False;
  while PipeTickMs < LDeadline do
  begin
    if FHarness.Eco('depois da reconexao mtls', 300) then
    begin
      LOk := True;
      Break;
    end;
    Sleep(50);
  end;
  AssertTrue('eco pos-reconexao nao voltou — handshake da reconexao falhou ' +
    'ou nao aconteceu', LOk);
end;

procedure TPipeTlsTests.Tls_ClienteValidaServidorPorPadrao_Recusa;
var
  LErro: string;
  LOk: Boolean;
begin
  // Guarda do DEFAULT seguro (SkipServerVerification=False): o cliente valida
  // a cadeia do servidor. O servidor apresenta o cert da PKI de teste, cuja CA
  // NAO esta no trust store do SO — a validacao tem de RECUSAR. Se alguem
  // reverter o default para "nao valida por padrao", so' este teste fica
  // vermelho: todos os outros desligam a validacao no harness.
  FHarness.Listen(''); // servidor TLS simples (sem mTLS): o unico motivo de
                       // recusa aqui e' o cliente reprovar o cert do servidor.
  LOk := FHarness.TryConnectValidandoServidor(LErro);
  AssertFalse('GRAVE: cliente aceitou servidor de PKI nao-confiavel com o ' +
    'default — a validacao do servidor esta desligada por padrao?', LOk);
  AssertFalse('cliente nao deveria autenticar contra servidor nao validado',
    FHarness.ClienteAutenticado(1000));
end;

procedure TPipeTlsTests.Mtls_ClienteSemCert_Recusado;
var
  LErro: string;
begin
  FHarness.Listen(Pki('ca_cert.pem'));
  FHarness.TryConnect('', LErro); // pode falhar no Connect ou logo depois
  // O observavel que vale e' este: OnClientConnected so dispara DEPOIS do
  // handshake, entao se ele nao veio, o cliente nao entrou.
  AssertFalse('GRAVE: cliente sem certificado foi autenticado (mTLS decorativo)',
    FHarness.ClienteAutenticado(2000));
  AssertFalse('GRAVE: cliente sem certificado conseguiu trafegar',
    FHarness.Eco('nao deveria passar', 1500));
end;

procedure TPipeTlsTests.Mtls_ClienteDeOutraCa_Recusado;
var
  LErro: string;
begin
  // O cert 'rogue' e' bem formado e tem o MESMO CN do legitimo; so' a CA
  // difere. Se a validacao algum dia olhar o nome em vez da cadeia, e' aqui
  // que aparece.
  FHarness.Listen(Pki('ca_cert.pem'));
  FHarness.TryConnect('rogue', LErro);
  AssertFalse('GRAVE: certificado de CA desconhecida foi aceito',
    FHarness.ClienteAutenticado(2000));
  AssertFalse('GRAVE: cliente de outra CA conseguiu trafegar',
    FHarness.Eco('nao deveria passar', 1500));
end;

procedure TPipeTlsTests.Mtls_ClienteAutoAssinado_Recusado;
var
  LErro: string;
begin
  // Distinto do teste anterior, e o mais dificil dos dois. O certificado
  // 'rogue' e' emitido por uma CA que o servidor nao conhece e nem recebe: a
  // cadeia fica INCOMPLETA, e isso sozinho ja reprova.
  //
  // O auto-assinado nao: ele e' a propria raiz, entao a cadeia FECHA, integra,
  // e o unico defeito e' "raiz desconhecida" — que e' exatamente o defeito que
  // uma PKI privada tem por definicao e que o servidor precisa tolerar para o
  // cliente legitimo funcionar. Sobra uma unica linha de defesa: conferir que
  // a raiz e' byte a byte a CA configurada.
  //
  // Sem este teste, apagar essa conferencia nao quebraria a suite. Foi
  // verificado sabotando-a de proposito: os outros testes seguiram verdes.
  FHarness.Listen(Pki('ca_cert.pem'));
  FHarness.TryConnect('selfsigned', LErro);
  AssertFalse('GRAVE: certificado auto-assinado foi aceito — a raiz da cadeia ' +
    'nao esta sendo comparada com a CA configurada',
    FHarness.ClienteAutenticado(2000));
  AssertFalse('GRAVE: cliente auto-assinado conseguiu trafegar',
    FHarness.Eco('nao deveria passar', 1500));
end;

procedure TPipeTlsTests.Mtls_ClienteDeCaGemea_Recusado;
var
  LErro: string;
begin
  // Cadeia gemea 'gemea_ca_cert.pem' tem o MESMO CN e o MESMO numero de serie
  // da CA real, so' a chave privada difere. Isso pinga o passo 3 de
  // VerifyClientChain (Pipes.Transport.Schannel.pas): a ancora de confianca e'
  // CertFindCertificateInStore(CERT_FIND_EXISTING, ...) sobre a raiz da cadeia
  // do cliente, e a doc da MS nao define o criterio de "exact match".
  //
  // No crypt32 do Windows nativo (o alvo desta biblioteca) a comparacao e' do
  // certificado INTEIRO, entao este teste passa trivialmente — nao ha
  // vulnerabilidade aqui. O valor e' travar contra uma troca futura por uma
  // comparacao mais fraca (ex.: so issuer+serial, como o Wine implementa) e
  // versionar a evidencia da fronteira. Ver memoria ptls-estado-e-armadilhas.
  FHarness.Listen(Pki('ca_cert.pem'));
  FHarness.TryConnect('gemea', LErro);
  AssertFalse('GRAVE: certificado de CA gemea (mesmo issuer+serial, chave ' +
    'diferente) foi aceito — a raiz da cadeia esta sendo comparada so por ' +
    'issuer+serial, nao pelo certificado inteiro',
    FHarness.ClienteAutenticado(2000));
  AssertFalse('GRAVE: cliente de CA gemea conseguiu trafegar',
    FHarness.Eco('nao deveria passar', 1500));
end;

procedure TPipeTlsTests.Handshake_ClienteMudo_EstouraNoPrazo;
var
  LMudo: TPipeClient;
  LT0: UInt64;
begin
  // Cliente ptTcp contra servidor ptTls: abre o socket e nunca manda o
  // ClientHello. Sem prazo de handshake, a reader thread daquela conexao
  // ficaria presa para sempre.
  FHarness.Server.TlsOptions.HandshakeTimeoutMs := 1500;
  FHarness.Listen('');
  LMudo := TPipeClient.Create(FAddr, ptTcp);
  try
    LT0 := PipeTickMs;
    LMudo.Connect(5000);
    // O sinal que de fato prova o timeout: o servidor tem de REPORTAR o erro
    // (OnError) sozinho, sem ninguem fechar a conexao. Sem o prazo, a reader
    // thread ficaria presa lendo e este evento nunca chegaria — daí esperar
    // pelo erro, e nao so' pela ausencia de autenticacao (que passaria mesmo
    // com a thread travada).
    AssertTrue('servidor nao abortou o handshake no prazo (reader presa?)',
      FHarness.EsperaErroServidor(4000));
    // O erro chegou perto do prazo (1500ms), nao no fim de uma espera longa.
    AssertTrue('servidor demorou muito alem do prazo do handshake',
      PipeTickMs - LT0 < 4000);
    AssertFalse('cliente mudo nao deveria ser autenticado',
      FHarness.ClienteAutenticado(200));
  finally
    LMudo.Free;
  end;
end;

procedure TPipeTlsTests.DoListenSemCredenciais;
var
  LSrv: TPipeServer;
begin
  LSrv := TPipeServer.Create(UniqueAddr, ptTls);
  try
    LSrv.Listen; // sem CertFile: nao ha servidor TLS possivel
  finally
    LSrv.Free;
  end;
end;

procedure TPipeTlsTests.Mtls_IdentidadeDoCliente_TrazCnDoCertificado;
var
  LErro: string;
  LId: TPipePeerIdentity;
begin
  FHarness.Listen(Pki('ca_cert.pem'));
  AssertTrue('cliente legitimo foi recusado: ' + LErro,
    FHarness.TryConnect('cli', LErro));
  AssertTrue('servidor nao autenticou o cliente',
    FHarness.ClienteAutenticado(5000));

  AssertTrue('servidor nao expos identidade do cliente autenticado',
    FHarness.Server.TryClientIdentity(FHarness.LastConnId, LId));
  // 'pdv-loja-001' e' o CN de cli_cert.pem. E' confiavel porque a cadeia foi
  // validada ANTES: o certificado 'rogue' carrega este mesmo CN de proposito e
  // nao chega ate aqui — e' recusado no handshake.
  AssertEquals('CN do cliente', 'pdv-loja-001', LId.CommonName);
  AssertTrue('Subject deveria conter o CN',
    Pos('pdv-loja-001', LId.Subject) > 0);

  // O contrato de publicacao: quem perguntar de dentro do proprio
  // OnClientConnected ja tem de enxergar a conexao anunciada.
  AssertTrue('identidade nao estava disponivel dentro de OnClientConnected',
    FHarness.IdentityNoHandler);
  AssertEquals('CN visto pelo handler', 'pdv-loja-001',
    FHarness.IdentityFromHandler.CommonName);
end;

procedure TPipeTlsTests.Tls_SemMtls_NaoTemIdentidade;
var
  LErro: string;
  LId: TPipePeerIdentity;
begin
  // TLS sem CaFile: o cliente nao apresenta certificado, entao nao ha
  // identidade — e False aqui significa "nao ha", nunca "ainda nao chegou".
  FHarness.Listen('');
  AssertTrue('cliente deveria conectar: ' + LErro,
    FHarness.TryConnect('', LErro));
  AssertTrue('servidor nao registrou o cliente',
    FHarness.ClienteAutenticado(5000));
  AssertFalse('sem mTLS nao deveria haver identidade',
    FHarness.Server.TryClientIdentity(FHarness.LastConnId, LId));
  AssertEquals('CN deveria vir vazio', '', LId.CommonName);
end;

procedure TPipeTlsTests.ClientIds_NaoListaConexaoEmHandshake;
var
  LMudo: TPipeClient;
begin
  // Cliente ptTcp contra servidor ptTls: o socket conecta e o TLS nunca
  // comeca. A conexao existe no servidor, mas nao esta estabelecida — e um
  // par que ainda nao se autenticou nao pode contar como cliente, senao um
  // painel mostraria clientes fantasmas e o Broadcast tentaria falar com quem
  // talvez seja recusado a seguir.
  //
  // Prazo alto de proposito: o teste precisa observar a conexao AINDA em
  // negociacao, nao depois de o servidor desistir dela.
  FHarness.Server.TlsOptions.HandshakeTimeoutMs := 30000;
  FHarness.Listen(Pki('ca_cert.pem'));
  LMudo := TPipeClient.Create(FAddr, ptTcp);
  try
    LMudo.Connect(5000);
    Sleep(700); // deixa o accept registrar a conexao
    AssertEquals('conexao em handshake nao deveria contar como cliente',
      0, FHarness.Server.ClientCount);
    AssertEquals('ClientIds nao deveria listar conexao em handshake',
      0, Length(FHarness.Server.ClientIds));
  finally
    LMudo.Free;
  end;
end;

procedure TPipeTlsTests.Mtls_AutoReconnectRecusado_NaoViraLacoQuente;
var
  LErro: string;
  LTentativas: Integer;
begin
  // Cliente com certificado que o servidor RECUSA, e AutoReconnect ligado.
  // A recusa nao se conserta sozinha, entao o cliente vai insistir — o que
  // NAO pode acontecer e' insistir sem intervalo.
  //
  // Regressao de um bug real, visto no sample ChatSeguro: no backend SChannel
  // o servidor completa o handshake e SO ENTAO valida a cadeia, entao o
  // cliente via "conectado" seguido de queda imediata. Esse caminho
  // ("conectou e caiu no mesmo instante") era tratado como SUCESSO: nao
  // contava tentativa e nao esperava nada, girando dezenas de vezes por
  // segundo contra um servidor que acabara de rejeitar a credencial.
  FHarness.Listen(Pki('ca_cert.pem'));
  FHarness.Client.AutoReconnect := True;
  FHarness.Client.ReconnectDelayMs := 400;
  FHarness.TryConnect('selfsigned', LErro); // recusado, aqui ou logo apos

  // Em ~2s, com 400ms de intervalo, cabem ~5 tentativas. Um laco quente faria
  // dezenas ou centenas. O teto e' folgado de proposito: o que se afirma e'
  // "ha espacamento", nao um numero exato.
  Sleep(2000);
  LTentativas := FHarness.CliConnCount + FHarness.CliDiscCount;
  AssertTrue('AutoReconnect virou laco quente: ' + IntToStr(LTentativas) +
    ' eventos de conexao em 2s com ReconnectDelayMs=400',
    LTentativas < 20);
end;

procedure TPipeTlsTests.AutoReconnectDesligadoNoCallback_ParaDeTentar;
var
  LErro: string;
  LAntes, LDepois: Integer;
begin
  // Uma aplicacao que reconhece recusa permanente desliga AutoReconnect de
  // dentro do proprio OnDisconnected (e' o que o sample ChatSeguro faz). Isso
  // so' funciona porque a flag e' RELIDA antes de cada tentativa: quando ela e'
  // alterada, ReaderFinished ja decidiu reconectar — em pdmMainThread o evento
  // nem rodou ainda, esta enfileirado para a thread da UI.
  FHarness.Listen(Pki('ca_cert.pem'));
  FHarness.Client.AutoReconnect := True;
  FHarness.Client.ReconnectDelayMs := 300;
  FHarness.DesligarReconexaoAoCair := True; // handler desliga na primeira queda
  FHarness.TryConnect('selfsigned', LErro);

  Sleep(1200);
  LAntes := FHarness.CliConnCount;
  Sleep(1500); // mais de 4 intervalos: se ainda tentasse, apareceria aqui
  LDepois := FHarness.CliConnCount;

  AssertEquals('depois de AutoReconnect:=False no callback nao deveria ' +
    'haver novas conexoes', LAntes, LDepois);
end;

procedure TPipeTlsTests.Mtls_MaxReconnectAttempts_AlcancaParQueAceitaEDerruba;
var
  LErro: string;
  LConns: Integer;
begin
  // O par mTLS no SChannel ACEITA o handshake e derruba ao reprovar a cadeia,
  // entao cada ciclo do cliente e' uma conexao que chega a abrir. Enquanto o
  // contador de tentativas viveu na thread de reconexao, esse caso reiniciava
  // o contador a cada ciclo (thread nova por ciclo) e o teto nunca chegava.
  FHarness.Listen(Pki('ca_cert.pem'));
  FHarness.Client.AutoReconnect := True;
  FHarness.Client.ReconnectDelayMs := 200;
  FHarness.Client.MaxReconnectAttempts := 3;
  FHarness.TryConnect('selfsigned', LErro);

  // 3 tentativas a 200ms cabem em ~1s; 3s da folga larga para desistir.
  Sleep(3000);
  LConns := FHarness.CliConnCount;
  Sleep(1500); // se ainda tentasse, apareceria aqui
  AssertEquals('depois de esgotar MaxReconnectAttempts nao deveria haver ' +
    'novas conexoes', LConns, FHarness.CliConnCount);
  // Teto de 3: a conexao inicial mais as tentativas. Um teto que nunca dispara
  // produziria dezenas.
  AssertTrue('esperava poucas conexoes ate desistir, houve ' +
    IntToStr(LConns), LConns <= 6);
end;

procedure TPipeTlsTests.Tls_ListenSemCredenciais_Falha;
var
  LLevantou: Boolean;
begin
  // Fail closed: melhor recusar a subir do que subir em texto claro.
  LLevantou := False;
  try
    DoListenSemCredenciais;
  except
    on E: EPipeTls do
      LLevantou := True;
  end;
  AssertTrue('Listen sem certificado deveria levantar EPipeTls', LLevantou);
end;

procedure TPipeTlsTests.DoTrocaCertComServidorAtivo;
begin
  FHarness.Server.TlsOptions.CertFile := 'outro.pfx';
end;

procedure TPipeTlsTests.Tls_TrocaCertComServidorAtivo_Levanta;
var
  LLevantou: Boolean;
begin
  FHarness.Listen('');
  // As credenciais sao lidas UMA vez, no Listen. Aceitar a troca aqui daria a
  // impressao de configuracao aplicada, sem efeito nenhum.
  LLevantou := False;
  try
    DoTrocaCertComServidorAtivo;
  except
    on E: EPipeError do
      LLevantou := True;
  end;
  AssertTrue('trocar CertFile com o servidor ativo deveria levantar', LLevantou);
end;

initialization
  TDUnitX.RegisterTestFixture(TPipeTlsTests);

{$ENDIF PIPES_TLS}

end.
