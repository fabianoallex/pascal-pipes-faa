unit uDeviceTestsMain;

{ Harness de testes em DEVICE para o backend Android (milestone A3).

  Por que nao e' fpcunit/DUnit como o resto da suite: o backend Android nao tem
  par dual-compiler (o FPC nao compila para Android neste projeto) e nao ha
  runner de console num APK. Entao aqui os casos sao codigo comum, rodados por
  uma thread e reportados numa tela — o criterio de aprovacao continua o mesmo
  de M7/H0-H4: nada pode passar de 2s, e o desbloqueio de leitura tem que ser
  em MILISSEGUNDOS, nao em segundos.

  Tudo roda em LOOPBACK (servidor e cliente no mesmo app, 127.0.0.1). E' por
  isso que o backend Android implementa listener apesar de a secao 13.1 dizer
  que servidor Android nao faz sentido no caso de uso: sem ele, verificar este
  backend dependeria de um servidor externo no ar e de uma rede funcionando,
  o que transformaria um teste de transporte num teste de infraestrutura.

  Os casos de ptTls PULAM (nao falham) quando os PEMs da PKI nao estao na pasta
  de documentos do app — ver LEIA-ME.md para como coloca-los la. }

interface

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.SyncObjs,
  FMX.Types,
  FMX.Controls,
  FMX.Forms,
  FMX.StdCtrls,
  FMX.Memo,
  FMX.Memo.Types,
  FMX.Layouts,
  FMX.Controls.Presentation,
  FMX.ScrollBox,
  Pipes.Types,
  Pipes.Threading,
  Pipes.Transport,
  Pipes.Base,
  Pipes.Client,
  Pipes.Server;

type
  TfrmDeviceTests = class(TForm)
    lytTopo: TLayout;
    btnRodar: TButton;
    lblResumo: TLabel;
    memLog: TMemo;
    procedure FormCreate(Sender: TObject);
    procedure btnRodarClick(Sender: TObject);
  private
    FRodando: Boolean;
    procedure Linha(const AText: string);
    procedure Resumo(const AText: string);
    procedure Terminou;
  end;

  /// Um caso falhou. Mensagem = o que se esperava e o que veio.
  ETesteFalhou = class(Exception);
  /// Um caso nao pode rodar neste aparelho (falta PKI, por exemplo). Nao conta
  /// como falha, mas aparece no resumo — pulado em silencio e' pior que
  /// vermelho: da a impressao de cobertura que nao existe.
  ETestePulado = class(Exception);

var
  frmDeviceTests: TfrmDeviceTests;

implementation

{$R *.fmx}

const
  // Faixa propria, longe de portas de servico. Cada caso pega uma porta
  // diferente para nao esbarrar em TIME_WAIT do caso anterior.
  PORTA_BASE = 45300;
  // Teto de M7/H0-H4: qualquer encerramento tem que caber aqui.
  LIMITE_ENCERRAMENTO_MS = 2000;
  // Teto do desbloqueio de leitura. O spike mediu ~1-2ms; 250ms ainda e'
  // "milissegundos" com folga enorme e nao vira teste instavel em aparelho
  // ocupado. O que este numero rejeita e' um mecanismo que so' destrava por
  // timeout de recv (centenas de ms) ou por keepalive (segundos).
  LIMITE_DESBLOQUEIO_MS = 250;

type
  TProcedimentoDeTeste = procedure of object;

  { Le de um endpoint ate' levantar. Serve ao caso do invariante #4: a thread
    fica genuinamente presa dentro do Read e o teste mede quanto tempo o
    CloseAbort leva para acorda-la. Dados capturados em CAMPOS, sem closure —
    mesmo padrao dos work items da lib. }
  TLeitorBloqueado = class(TThread)
  private
    FEndpoint: TPipeEndpoint;
    FSaiuEm: UInt64;      // PipeTickMs quando o Read levantou
    FErro: string;
  protected
    procedure Execute; override;
  public
    constructor Create(AEndpoint: TPipeEndpoint);
    property SaiuEm: UInt64 read FSaiuEm;
    property Erro: string read FErro;
  end;

  { Aceita UMA conexao e guarda o endpoint. }
  TAceitadorUnico = class(TThread)
  private
    FListener: TPipeListener;
    FEndpoint: TPipeEndpoint;
  protected
    procedure Execute; override;
  public
    constructor Create(AListener: TPipeListener);
    property Endpoint: TPipeEndpoint read FEndpoint;
  end;

  { Roda a bateria fora da thread da UI e devolve cada linha por Synchronize. }
  TExecutorDeTestes = class(TThread)
  private
    FForm: TfrmDeviceTests;
    FLinha: string;       // buffer do Synchronize (uma linha por vez)
    FOk, FFalhas, FPulados: Integer;
    FPortaAtual: Integer;
    // --- infraestrutura ---
    procedure Emite;
    procedure EmiteResumo;
    procedure Avisa(const AText: string);
    procedure Roda(const ANome: string; AProc: TProcedimentoDeTeste);
    function ProximoEndereco: string;
    function PkiDir: string;
    function Pki(const AFile: string): string;
    procedure ExigePki;
    /// PULA o caso se QUALQUER um dos arquivos nao estiver no aparelho. Cada
    /// teste declara o que usa; ver o corpo para o porque de nao bastar o
    /// ExigePki generico.
    procedure ExigePkiArquivos(const ANomes: array of string);
    /// Levanta se AErro for a falha do CARREGADOR do OpenSSL, e nao um
    /// veredito de certificado. Ver o corpo para o porque disto existir.
    procedure ExigeVeredictoDeTls(const AErro: string);
    procedure Verdadeiro(ACond: Boolean; const AMsg: string);
    // --- casos ---
    procedure Local_RecusadoComMensagemClara;
    procedure Tcp_EcoLoopback;
    procedure Tcp_RequestReply;
    procedure Invariante4_CloseAbortDestravaLeituraEmMilissegundos;
    procedure Disconnect_ConexaoOciosa_AbaixoDoLimite;
    procedure Stop_ConexaoOciosa_AbaixoDoLimite;
    procedure Stop_SobTrafegoIntenso_AbaixoDoLimite;
    procedure QuedaAbrupta_DisparaOnClientDisconnected;
    procedure Tls_ClienteLegitimo_Conecta;
    procedure Tls_CaDesconhecida_Recusada;
    procedure Tls_AutoAssinadoSobMtls_Recusado;
  protected
    procedure Execute; override;
  public
    constructor Create(AForm: TfrmDeviceTests);
  end;

{ ---------------------------------------------------------------------------
  Coletor de eventos: um contador simples, com espera por deadline. Evita
  Sleep fixo espalhado pelos casos (que e' o que torna teste de rede instavel).
  --------------------------------------------------------------------------- }

type
  TColetor = class
  private
    FLock: TCriticalSection;
    FContagem: Integer;
    FUltimoTexto: string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Registra(const ATexto: string);
    function Espera(AQuantos: Integer; ATimeoutMs: Cardinal): Boolean;
    function UltimoTexto: string;
    function Contagem: Integer;
  end;

constructor TColetor.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TColetor.Destroy;
begin
  FLock.Free;
  inherited;
end;

procedure TColetor.Registra(const ATexto: string);
begin
  FLock.Enter;
  try
    Inc(FContagem);
    FUltimoTexto := ATexto;
  finally
    FLock.Leave;
  end;
end;

function TColetor.Contagem: Integer;
begin
  FLock.Enter;
  try
    Result := FContagem;
  finally
    FLock.Leave;
  end;
end;

function TColetor.UltimoTexto: string;
begin
  FLock.Enter;
  try
    Result := FUltimoTexto;
  finally
    FLock.Leave;
  end;
end;

function TColetor.Espera(AQuantos: Integer; ATimeoutMs: Cardinal): Boolean;
var
  LDeadline: UInt64;
begin
  LDeadline := PipeTickMs + ATimeoutMs;
  repeat
    if Contagem >= AQuantos then
      Exit(True);
    Sleep(10);
  until Int64(LDeadline) - Int64(PipeTickMs) <= 0;
  Result := Contagem >= AQuantos;
end;

{ Handlers de evento precisam ser 'of object'; um objeto leve carrega os
  coletores para nao poluir a thread executora com dezenas de campos. }
type
  TGanchos = class
  public
    Mensagens: TColetor;
    Conectados: TColetor;
    Desconectados: TColetor;
    Erros: TColetor;
    constructor Create;
    destructor Destroy; override;
    procedure AoReceber(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure AoConectar(Sender: TObject; AConnId: TPipeConnectionId);
    procedure AoDesconectar(Sender: TObject; AConnId: TPipeConnectionId);
    procedure AoErrar(Sender: TObject; AConnId: TPipeConnectionId;
      const AError: string);
    procedure AoPedir(Sender: TObject; AConnId: TPipeConnectionId;
      const ARequest: TBytes; out AReply: TBytes);
  end;

constructor TGanchos.Create;
begin
  inherited Create;
  Mensagens := TColetor.Create;
  Conectados := TColetor.Create;
  Desconectados := TColetor.Create;
  Erros := TColetor.Create;
end;

destructor TGanchos.Destroy;
begin
  Mensagens.Free;
  Conectados.Free;
  Desconectados.Free;
  Erros.Free;
  inherited;
end;

procedure TGanchos.AoReceber(Sender: TObject; AConnId: TPipeConnectionId;
  const AData: TBytes);
begin
  Mensagens.Registra(TEncoding.UTF8.GetString(AData));
end;

procedure TGanchos.AoConectar(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Conectados.Registra('');
end;

procedure TGanchos.AoDesconectar(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Desconectados.Registra('');
end;

procedure TGanchos.AoErrar(Sender: TObject; AConnId: TPipeConnectionId;
  const AError: string);
begin
  Erros.Registra(AError);
end;

procedure TGanchos.AoPedir(Sender: TObject; AConnId: TPipeConnectionId;
  const ARequest: TBytes; out AReply: TBytes);
begin
  AReply := TEncoding.UTF8.GetBytes('re:' + TEncoding.UTF8.GetString(ARequest));
end;

{ TLeitorBloqueado }

constructor TLeitorBloqueado.Create(AEndpoint: TPipeEndpoint);
begin
  inherited Create(True);
  FEndpoint := AEndpoint;
end;

procedure TLeitorBloqueado.Execute;
var
  LBuf: array[0..255] of Byte;
begin
  try
    // Ninguem vai escrever nada: isto fica preso dentro do poll/recv ate' que
    // outra thread chame CloseAbort. E' exatamente o cenario do invariante #4.
    FEndpoint.Read(LBuf[0], SizeOf(LBuf));
    FErro := 'Read retornou em vez de levantar';
  except
    on EPipeClosed do
      FErro := ''; // o esperado
    on E: Exception do
      FErro := 'excecao inesperada ' + E.ClassName + ': ' + E.Message;
  end;
  FSaiuEm := PipeTickMs;
end;

{ TAceitadorUnico }

constructor TAceitadorUnico.Create(AListener: TPipeListener);
begin
  inherited Create(True);
  FListener := AListener;
end;

procedure TAceitadorUnico.Execute;
begin
  try
    FEndpoint := FListener.Accept;
  except
    FEndpoint := nil;
  end;
end;

{ TExecutorDeTestes }

constructor TExecutorDeTestes.Create(AForm: TfrmDeviceTests);
begin
  inherited Create(True);
  FreeOnTerminate := True;
  FForm := AForm;
  FPortaAtual := PORTA_BASE;
end;

procedure TExecutorDeTestes.Emite;
begin
  FForm.Linha(FLinha);
end;

procedure TExecutorDeTestes.EmiteResumo;
begin
  FForm.Resumo(FLinha);
  FForm.Terminou;
end;

procedure TExecutorDeTestes.Avisa(const AText: string);
begin
  FLinha := AText;
  Synchronize(Emite);
end;

function TExecutorDeTestes.ProximoEndereco: string;
begin
  Inc(FPortaAtual);
  Result := '127.0.0.1:' + IntToStr(FPortaAtual);
end;

function TExecutorDeTestes.PkiDir: string;
begin
  Result := IncludeTrailingPathDelimiter(TPath.GetDocumentsPath);
end;

function TExecutorDeTestes.Pki(const AFile: string): string;
begin
  Result := PkiDir + AFile;
end;

procedure TExecutorDeTestes.ExigePki;
begin
  if not FileExists(Pki('ca_cert.pem')) then
    raise ETestePulado.Create('PKI ausente em ' + PkiDir +
      ' (ver LEIA-ME.md)');
end;

procedure TExecutorDeTestes.ExigePkiArquivos(const ANomes: array of string);
var
  I: Integer;
  LFaltando: string;
begin
  // ExigePki so' confere ca_cert.pem, o que nao basta: cada caso usa um
  // conjunto diferente, e um PEM que faltou no Deployment vira uma falha de
  // CARREGAMENTO ("nao foi possivel carregar a CA"), nao um veredito de
  // certificado. Nos casos negativos isso satisfaria o "houve excecao" e
  // passaria em VERDE sem ter validado nada — a mesma classe de mentira que o
  // ExigeVeredictoDeTls fecha para o backend ausente.
  //
  // Aconteceu de verdade: uma lista de Deployment montada a mao trocou
  // gemea_ca_cert.pem (o certificado) por gemea_ca_key.pem (a chave privada).
  LFaltando := '';
  for I := Low(ANomes) to High(ANomes) do
    if not FileExists(Pki(ANomes[I])) then
      LFaltando := LFaltando + ANomes[I] + ' ';
  if LFaltando <> '' then
    raise ETestePulado.Create('faltam no aparelho: ' + Trim(LFaltando) +
      ' (confira o Deployment; ver LEIA-ME.md)');
end;

procedure TExecutorDeTestes.ExigeVeredictoDeTls(const AErro: string);
begin
  // Os casos NEGATIVOS de TLS (CA desconhecida, auto-assinado sob mTLS) provam
  // que a conexao foi RECUSADA. Mas "recusada" nao pode ser satisfeita por
  // qualquer exceção: sem libssl/libcrypto no aparelho, o EnsureOpenSsl levanta
  // EPipeTls antes de qualquer byte de TLS sair, e o caso passaria em VERDE sem
  // ter exercitado validacao nenhuma. Foi o que aconteceu na primeira rodada com
  // a PKI presente e as .so ausentes: "10 ok" com dois verdes falsos.
  //
  // Este guarda transforma esse cenario em falha barulhenta. Um caso de TLS que
  // passa porque o TLS nao existe e' pior que um caso vermelho: ele mente sobre
  // a cobertura.
  if (Pos('OpenSSL', AErro) > 0)
    and ((Pos('encontrado', AErro) > 0) or (Pos('simbolo', AErro) > 0)
         or (Pos('símbolo', AErro) > 0)) then
    raise ETesteFalhou.Create(
      'backend TLS ausente, este caso nao provou nada — empacote ' +
      'libcrypto.so/libssl.so por ABI (ver samples/EchoAndroid/LEIA-ME.md). ' +
      'Erro do carregador: ' + AErro);
end;

procedure TExecutorDeTestes.Verdadeiro(ACond: Boolean; const AMsg: string);
begin
  if not ACond then
    raise ETesteFalhou.Create(AMsg);
end;

procedure TExecutorDeTestes.Roda(const ANome: string;
  AProc: TProcedimentoDeTeste);
var
  LInicio: UInt64;
begin
  LInicio := PipeTickMs;
  try
    AProc;
    Inc(FOk);
    Avisa(Format('  OK     %s (%d ms)', [ANome, PipeTickMs - LInicio]));
  except
    on E: ETestePulado do
    begin
      Inc(FPulados);
      Avisa(Format('  PULADO %s - %s', [ANome, E.Message]));
    end;
    on E: Exception do
    begin
      Inc(FFalhas);
      Avisa(Format('  FALHOU %s - %s: %s', [ANome, E.ClassName, E.Message]));
    end;
  end;
end;

{ --- casos ---------------------------------------------------------------- }

procedure TExecutorDeTestes.Local_RecusadoComMensagemClara;
var
  LClient: TPipeClient;
  LMensagem: string;
begin
  // A0: no Android ptLocal nao existe e a recusa tem que ser explicita, nao um
  // erro obscuro de socket la na frente.
  LMensagem := '';
  LClient := TPipeClient.Create('meupipe');
  try
    LClient.Transport := ptLocal;
    try
      LClient.Connect(500);
    except
      on E: Exception do
        LMensagem := E.Message;
    end;
  finally
    LClient.Free;
  end;
  Verdadeiro(LMensagem <> '', 'ptLocal conectou (deveria ter sido recusado)');
  Verdadeiro(Pos('ptLocal', LMensagem) > 0,
    'a mensagem nao explica que ptLocal nao existe aqui: ' + LMensagem);
end;

procedure TExecutorDeTestes.Tcp_EcoLoopback;
var
  LServer: TPipeServer;
  LClient: TPipeClient;
  LG: TGanchos;
  LEndereco: string;
begin
  LEndereco := ProximoEndereco;
  LG := TGanchos.Create;
  LServer := TPipeServer.Create(LEndereco);
  LClient := TPipeClient.Create(LEndereco);
  try
    LServer.Transport := ptTcp;
    LClient.Transport := ptTcp;
    LClient.OnMessage := LG.AoReceber;
    LServer.OnMessage := LG.AoReceber;
    LServer.Listen;
    LClient.Connect(3000);
    LClient.SendText('ping android');
    Verdadeiro(LG.Mensagens.Espera(1, 3000),
      'o servidor nao recebeu a mensagem do cliente');
    Verdadeiro(LG.Mensagens.UltimoTexto = 'ping android',
      'o texto chegou diferente: ' + LG.Mensagens.UltimoTexto);
  finally
    LClient.Free;
    LServer.Free;
    LG.Free;
  end;
end;

procedure TExecutorDeTestes.Tcp_RequestReply;
var
  LServer: TPipeServer;
  LClient: TPipeClient;
  LG: TGanchos;
  LEndereco, LResposta: string;
begin
  LEndereco := ProximoEndereco;
  LG := TGanchos.Create;
  LServer := TPipeServer.Create(LEndereco);
  LClient := TPipeClient.Create(LEndereco);
  try
    LServer.Transport := ptTcp;
    LClient.Transport := ptTcp;
    LServer.OnRequest := LG.AoPedir;
    LServer.Listen;
    LClient.Connect(3000);
    LResposta := LClient.RequestText('oi', 5000);
    Verdadeiro(LResposta = 're:oi', 'resposta inesperada: ' + LResposta);
  finally
    LClient.Free;
    LServer.Free;
    LG.Free;
  end;
end;

procedure TExecutorDeTestes.Invariante4_CloseAbortDestravaLeituraEmMilissegundos;
var
  LListener: TPipeListener;
  LAceitador: TAceitadorUnico;
  LCliente, LServidor: TPipeEndpoint;
  LLeitor: TLeitorBloqueado;
  LEndereco: string;
  LAbortouEm: UInt64;
  LDecorrido: Int64;
begin
  // O caso central deste backend, medido no transporte CRU (sem TPipeClient no
  // caminho): uma thread presa dentro do Read e outra chamando CloseAbort.
  LEndereco := ProximoEndereco;
  LListener := PipeCreateListener(LEndereco, ptTcp, 0);
  LAceitador := nil;
  LCliente := nil;
  LServidor := nil;
  LLeitor := nil;
  try
    LAceitador := TAceitadorUnico.Create(LListener);
    LAceitador.Start;
    LCliente := PipeConnect(LEndereco, 3000, ptTcp, 0);
    LAceitador.WaitFor;
    LServidor := LAceitador.Endpoint;
    Verdadeiro(LServidor <> nil, 'o Accept nao devolveu endpoint');

    LLeitor := TLeitorBloqueado.Create(LServidor);
    LLeitor.Start;
    // Folga para o Read entrar de fato no poll antes do abort. Sem isso o
    // teste poderia medir um Read que nem chegou a bloquear.
    Sleep(300);

    LAbortouEm := PipeTickMs;
    LServidor.CloseAbort;
    Verdadeiro(LLeitor.WaitFor = 0, 'a thread de leitura nao terminou');

    Verdadeiro(LLeitor.Erro = '', 'o Read nao levantou: ' + LLeitor.Erro);
    LDecorrido := Int64(LLeitor.SaiuEm) - Int64(LAbortouEm);
    if LDecorrido < 0 then
      LDecorrido := 0;
    Avisa(Format('         (desbloqueio medido: %d ms)', [LDecorrido]));
    Verdadeiro(LDecorrido <= LIMITE_DESBLOQUEIO_MS,
      Format('o CloseAbort levou %d ms para destravar o Read (limite %d ms) — ' +
        'isso indica desbloqueio por timeout/keepalive, nao por evento',
        [LDecorrido, LIMITE_DESBLOQUEIO_MS]));
  finally
    LLeitor.Free;
    LAceitador.Free;
    LServidor.Free;
    LCliente.Free;
    LListener.Free;
  end;
end;

procedure TExecutorDeTestes.Disconnect_ConexaoOciosa_AbaixoDoLimite;
var
  LServer: TPipeServer;
  LClient: TPipeClient;
  LEndereco: string;
  LInicio: UInt64;
  LDecorrido: Int64;
begin
  LEndereco := ProximoEndereco;
  LServer := TPipeServer.Create(LEndereco);
  LClient := TPipeClient.Create(LEndereco);
  try
    LServer.Transport := ptTcp;
    LClient.Transport := ptTcp;
    LServer.Listen;
    LClient.Connect(3000);
    Sleep(200); // conexao parada, sem nenhum trafego: o pior caso do Stop
    LInicio := PipeTickMs;
    LClient.Disconnect;
    LDecorrido := Int64(PipeTickMs) - Int64(LInicio);
    Avisa(Format('         (Disconnect: %d ms)', [LDecorrido]));
    Verdadeiro(LDecorrido < LIMITE_ENCERRAMENTO_MS,
      Format('Disconnect levou %d ms (limite %d)',
        [LDecorrido, LIMITE_ENCERRAMENTO_MS]));
  finally
    LClient.Free;
    LServer.Free;
  end;
end;

procedure TExecutorDeTestes.Stop_ConexaoOciosa_AbaixoDoLimite;
var
  LServer: TPipeServer;
  LClient: TPipeClient;
  LEndereco: string;
  LInicio: UInt64;
  LDecorrido: Int64;
begin
  LEndereco := ProximoEndereco;
  LServer := TPipeServer.Create(LEndereco);
  LClient := TPipeClient.Create(LEndereco);
  try
    LServer.Transport := ptTcp;
    LClient.Transport := ptTcp;
    LServer.Listen;
    LClient.Connect(3000);
    Sleep(200);
    LInicio := PipeTickMs;
    LServer.Stop; // precisa acordar acceptor E reader pelo self-pipe
    LDecorrido := Int64(PipeTickMs) - Int64(LInicio);
    Avisa(Format('         (Stop: %d ms)', [LDecorrido]));
    Verdadeiro(LDecorrido < LIMITE_ENCERRAMENTO_MS,
      Format('Stop levou %d ms (limite %d)',
        [LDecorrido, LIMITE_ENCERRAMENTO_MS]));
  finally
    LClient.Free;
    LServer.Free;
  end;
end;

procedure TExecutorDeTestes.Stop_SobTrafegoIntenso_AbaixoDoLimite;
var
  LServer: TPipeServer;
  LClient: TPipeClient;
  LG: TGanchos;
  LEndereco: string;
  LInicio: UInt64;
  LDecorrido: Int64;
  I: Integer;
begin
  LEndereco := ProximoEndereco;
  LG := TGanchos.Create;
  LServer := TPipeServer.Create(LEndereco);
  LClient := TPipeClient.Create(LEndereco);
  try
    LServer.Transport := ptTcp;
    LClient.Transport := ptTcp;
    LServer.OnMessage := LG.AoReceber;
    LServer.Listen;
    LClient.Connect(3000);
    // Enche a fila do outro lado: o Stop tem que interromper reader e pool no
    // meio do fluxo, nao esperar drenar.
    for I := 1 to 2000 do
    try
      LClient.SendText('carga ' + IntToStr(I));
    except
      Break; // o servidor pode cair antes; nao e' isto que se mede aqui
    end;
    LInicio := PipeTickMs;
    LServer.Stop;
    LDecorrido := Int64(PipeTickMs) - Int64(LInicio);
    Avisa(Format('         (Stop sob carga: %d ms, %d msgs vistas)',
      [LDecorrido, LG.Mensagens.Contagem]));
    Verdadeiro(LDecorrido < LIMITE_ENCERRAMENTO_MS,
      Format('Stop sob carga levou %d ms (limite %d)',
        [LDecorrido, LIMITE_ENCERRAMENTO_MS]));
  finally
    LClient.Free;
    LServer.Free;
    LG.Free;
  end;
end;

procedure TExecutorDeTestes.QuedaAbrupta_DisparaOnClientDisconnected;
var
  LServer: TPipeServer;
  LCru: TPipeEndpoint;
  LG: TGanchos;
  LEndereco: string;
begin
  LEndereco := ProximoEndereco;
  LG := TGanchos.Create;
  LServer := TPipeServer.Create(LEndereco);
  try
    LServer.Transport := ptTcp;
    LServer.OnClientConnected := LG.AoConectar;
    LServer.OnClientDisconnected := LG.AoDesconectar;
    LServer.Listen;
    // Endpoint CRU: conecta e some sem despedida nenhuma da camada de cima.
    LCru := PipeConnect(LEndereco, 3000, ptTcp, 0);
    try
      Verdadeiro(LG.Conectados.Espera(1, 3000),
        'OnClientConnected nao disparou');
    finally
      LCru.Free; // fecha o fd: o servidor ve EOF
    end;
    Verdadeiro(LG.Desconectados.Espera(1, 3000),
      'OnClientDisconnected nao disparou apos a queda abrupta');
  finally
    LServer.Free;
    LG.Free;
  end;
end;

procedure TExecutorDeTestes.Tls_ClienteLegitimo_Conecta;
var
  LServer: TPipeServer;
  LClient: TPipeClient;
  LG: TGanchos;
  LEndereco: string;
begin
  ExigePki;
  ExigePkiArquivos(['srv_cert.pem', 'srv_key.pem', 'ca_cert.pem',
    'cli_cert.pem', 'cli_key.pem']);
  LEndereco := ProximoEndereco;
  LG := TGanchos.Create;
  LServer := TPipeServer.Create(LEndereco);
  LClient := TPipeClient.Create(LEndereco);
  try
    LServer.Transport := ptTls;
    LServer.TlsOptions.CertFile := Pki('srv_cert.pem');
    LServer.TlsOptions.KeyFile := Pki('srv_key.pem');
    LServer.TlsOptions.CaFile := Pki('ca_cert.pem'); // liga mTLS
    LServer.OnMessage := LG.AoReceber;
    LServer.Listen;

    LClient.Transport := ptTls;
    LClient.TlsOptions.CaFile := Pki('ca_cert.pem');
    LClient.TlsOptions.CertFile := Pki('cli_cert.pem');
    LClient.TlsOptions.KeyFile := Pki('cli_key.pem');
    LClient.Connect(8000);
    LClient.SendText('tls ok');
    Verdadeiro(LG.Mensagens.Espera(1, 5000),
      'o eco cifrado nao chegou ao servidor');
  finally
    LClient.Free;
    LServer.Free;
    LG.Free;
  end;
end;

procedure TExecutorDeTestes.Tls_CaDesconhecida_Recusada;
var
  LServer: TPipeServer;
  LClient: TPipeClient;
  LEndereco, LErro: string;
begin
  ExigePki;
  ExigePkiArquivos(['srv_cert.pem', 'srv_key.pem', 'gemea_ca_cert.pem']);
  LEndereco := ProximoEndereco;
  LServer := TPipeServer.Create(LEndereco);
  LClient := TPipeClient.Create(LEndereco);
  try
    LServer.Transport := ptTls;
    LServer.TlsOptions.CertFile := Pki('srv_cert.pem');
    LServer.TlsOptions.KeyFile := Pki('srv_key.pem');
    LServer.Listen;

    // Cliente exige uma CA que NAO assinou o servidor: a cadeia tem que ser
    // rejeitada, e o veredito tem que ser de TLS, nao um erro generico.
    LClient.Transport := ptTls;
    LClient.TlsOptions.CaFile := Pki('gemea_ca_cert.pem');
    LErro := '';
    try
      LClient.Connect(8000);
    except
      on E: Exception do
        LErro := E.ClassName + ': ' + E.Message;
    end;
    Verdadeiro(LErro <> '',
      'GRAVE: servidor de CA desconhecida foi aceito pelo cliente');
    ExigeVeredictoDeTls(LErro); // recusa tem que ser de certificado, nao do loader
    Avisa('         (veredito: ' + LErro + ')');
  finally
    LClient.Free;
    LServer.Free;
  end;
end;

procedure TExecutorDeTestes.Tls_AutoAssinadoSobMtls_Recusado;
var
  LServer: TPipeServer;
  LClient: TPipeClient;
  LG: TGanchos;
  LEndereco, LErro: string;
begin
  ExigePki;
  ExigePkiArquivos(['srv_cert.pem', 'srv_key.pem', 'ca_cert.pem',
    'selfsigned_cert.pem', 'selfsigned_key.pem']);
  LEndereco := ProximoEndereco;
  LG := TGanchos.Create;
  LServer := TPipeServer.Create(LEndereco);
  LClient := TPipeClient.Create(LEndereco);
  try
    LServer.Transport := ptTls;
    LServer.TlsOptions.CertFile := Pki('srv_cert.pem');
    LServer.TlsOptions.KeyFile := Pki('srv_key.pem');
    LServer.TlsOptions.CaFile := Pki('ca_cert.pem'); // mTLS ligado
    LServer.OnMessage := LG.AoReceber;
    LServer.Listen;

    // Cliente com certificado que ele mesmo assinou: sob mTLS tem que ser
    // recusado, e por motivo DIFERENTE do caso da CA desconhecida (la quem
    // recusa e' o cliente; aqui e' o servidor).
    LClient.Transport := ptTls;
    LClient.TlsOptions.CaFile := Pki('ca_cert.pem');
    LClient.TlsOptions.CertFile := Pki('selfsigned_cert.pem');
    LClient.TlsOptions.KeyFile := Pki('selfsigned_key.pem');
    LErro := '';
    try
      LClient.Connect(8000);
      LClient.SendText('nao deveria passar');
    except
      on E: Exception do
        LErro := E.ClassName + ': ' + E.Message;
    end;
    // A ordem importa: checar o loader ANTES do silencio da fila. Sem OpenSSL
    // nenhuma mensagem chega, e o "nao trafegou" seria satisfeito pelo motivo
    // errado.
    ExigeVeredictoDeTls(LErro);
    Verdadeiro(not LG.Mensagens.Espera(1, 1500),
      'GRAVE: cliente auto-assinado trafegou sob mTLS');
    Avisa('         (veredito: ' + LErro + ')');
  finally
    LClient.Free;
    LServer.Free;
    LG.Free;
  end;
end;

procedure TExecutorDeTestes.Execute;
begin
  FOk := 0;
  FFalhas := 0;
  FPulados := 0;
  Avisa('--- transporte (A0/A1) ---');
  Roda('ptLocal recusado com mensagem clara', Local_RecusadoComMensagemClara);
  Roda('eco loopback ptTcp', Tcp_EcoLoopback);
  Roda('request/reply ptTcp', Tcp_RequestReply);
  Avisa('--- invariante #4 e encerramento ---');
  Roda('CloseAbort destrava Read em ms',
    Invariante4_CloseAbortDestravaLeituraEmMilissegundos);
  Roda('Disconnect com conexao ociosa', Disconnect_ConexaoOciosa_AbaixoDoLimite);
  Roda('Stop com conexao ociosa', Stop_ConexaoOciosa_AbaixoDoLimite);
  Roda('Stop sob trafego intenso', Stop_SobTrafegoIntenso_AbaixoDoLimite);
  Roda('queda abrupta notifica o servidor',
    QuedaAbrupta_DisparaOnClientDisconnected);
  Avisa('--- ptTls / OpenSSL (A2) ---');
  Roda('mTLS com cliente legitimo', Tls_ClienteLegitimo_Conecta);
  Roda('CA desconhecida recusada', Tls_CaDesconhecida_Recusada);
  Roda('auto-assinado sob mTLS recusado', Tls_AutoAssinadoSobMtls_Recusado);

  FLinha := Format('%d ok, %d falha(s), %d pulado(s)',
    [FOk, FFalhas, FPulados]);
  Synchronize(EmiteResumo);
end;

{ TfrmDeviceTests }

procedure TfrmDeviceTests.FormCreate(Sender: TObject);
begin
  lblResumo.Text := 'toque em Rodar';
  Linha('Testes de device do backend Android.');
  Linha('Dica: rode uma vez, mande o app para segundo plano, volte e rode de');
  Linha('novo — o desbloqueio de leitura tem que continuar em milissegundos.');
  Linha('');
end;

procedure TfrmDeviceTests.btnRodarClick(Sender: TObject);
begin
  if FRodando then
    Exit;
  FRodando := True;
  btnRodar.Enabled := False;
  lblResumo.Text := 'rodando...';
  memLog.Lines.Clear;
  TExecutorDeTestes.Create(Self).Start;
end;

procedure TfrmDeviceTests.Linha(const AText: string);
begin
  memLog.Lines.Add(AText);
  memLog.GoToTextEnd;
end;

procedure TfrmDeviceTests.Resumo(const AText: string);
begin
  lblResumo.Text := AText;
  Linha('');
  Linha('=== ' + AText + ' ===');
end;

procedure TfrmDeviceTests.Terminou;
begin
  FRodando := False;
  btnRodar.Enabled := True;
end;

end.
