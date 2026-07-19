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
    FErroEvt: TEvent;   // sinalizado quando o servidor reporta um erro de conexao
    FRecebido: string;
    FErroServidor: string;
    procedure OnServerMsg(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure OnClientMsg(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure OnClientConnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnServerError(Sender: TObject; AConnId: TPipeConnectionId;
      const AMsg: string);
  public
    constructor Create(const AAddress: string);
    destructor Destroy; override;
    property Server: TPipeServer read FServer;
    property Client: TPipeClient read FClient;
    /// Sobe o servidor. ACaFile <> '' liga mTLS.
    procedure Listen(const ACaFile: string);
    /// Conecta o cliente; ACliCert <> '' apresenta certificado (mTLS).
    /// Devolve False (sem levantar) se a conexao foi recusada.
    function TryConnect(const ACliCert: string; out AErro: string): Boolean;
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
    // --- recusa (o que de fato prova que ha autenticacao) ---
    [Test] procedure Mtls_ClienteSemCert_Recusado;
    [Test] procedure Mtls_ClienteDeOutraCa_Recusado;
    [Test] procedure Mtls_ClienteAutoAssinado_Recusado;
    [Test] procedure Handshake_ClienteMudo_EstouraNoPrazo;
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
  FConnected.SetEvent;
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
