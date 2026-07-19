unit Pipes.Transport.Tls;

{$I pipes.inc}

{ Transporte TLS (ptTls): TCP com a sessao cifrada por cima.

  Esta unit e' o ponto NEUTRO — nao implementa TLS. Ela escolhe o backend e faz
  a adaptacao de contratos:

    backend TLS                  quem implementa
    Windows .................... Pipes.Transport.Schannel (SSPI nativo; nao
                                 depende de DLL externa — decisivo em parque de
                                 maquinas antigo, onde distribuir e atualizar
                                 OpenSSL e' problema operacional)
    POSIX (e Windows opt-in) ... Pipes.Transport.OpenSSL (libssl/libcrypto
                                 carregadas dinamicamente)

  A adaptacao existe porque os dois lados falam linguas diferentes:

    TPipeEndpoint  --TPipeEndpointStream-->  TStream  --backend TLS-->  TStream
                                                                          |
    TPipeTlsEndpoint <--------------------------------------------------- +

  Ou seja: o endpoint TCP vira TStream, o backend cifra sobre esse TStream, e
  TPipeTlsEndpoint traz o resultado de volta ao contrato TPipeEndpoint que o
  resto da lib conhece. O framing NPF1 nao sabe que ha TLS embaixo.

  Invariantes (alem do contrato de Pipes.Transport):
  - POSSE: o stream do backend e' dono do TStream de baixo (libera os dois no
    Free), mas NAO do TPipeEndpoint TCP — esse e' liberado aqui. Ordem no
    destructor: primeiro o stream TLS (que tenta o close_notify), depois o
    endpoint.
  - ABORT: CloseAbort delega ao endpoint TCP. Uma leitura presa no backend TLS
    esta, na pratica, presa no Read do endpoint de baixo; abortar aquele faz o
    EPipeClosed subir pela pilha de decifragem. Nao ha estado a desarmar no
    proprio TLS.
  - O contrato de Read difere do TStream: aqui Read NUNCA devolve 0 — fim de
    conexao e' EPipeClosed. A conversao e' feita neste adaptador.

  Seguranca: o handshake do backend e' SINCRONO e acontece na construcao. Do
  lado cliente isso e' inofensivo (quem chama e' quem espera). Do lado
  SERVIDOR seria feito logo apos o accept, e um cliente que trave no meio do
  handshake bloquearia a thread de accept inteira — por isso o servidor ptTls
  ainda nao esta habilitado aqui (ver T1/T2 no README). }

interface

uses
  SysUtils,
  Classes,
  Pipes.Types,
  Pipes.Transport;

type
  { Embrulha um TPipeEndpoint ja conectado numa sessao TLS. Assume a posse do
    endpoint de baixo. }
  TPipeTlsEndpoint = class(TPipeEndpoint)
  private
    FInner: TPipeEndpoint;   // endpoint TCP; propriedade desta classe
    FTls: TStream;           // stream do backend; dono do TPipeEndpointStream
  public
    /// ATargetName e' o nome usado para SNI e para validar o certificado
    /// (tipicamente o host de Address). AVerifyPeer=False desliga a validacao
    /// da cadeia — util so em laboratorio, nunca em producao.
    constructor Create(AInner: TPipeEndpoint; const ATargetName: string;
      AVerifyPeer: Boolean);
    destructor Destroy; override;
    function Read(var ABuffer; ACount: Integer): Integer; override;
    procedure WriteExactly(const ABuffer; ACount: Integer); override;
    procedure CloseAbort; override;
  end;

/// Conecta via TCP e faz o handshake TLS como CLIENTE.
function TlsPipeConnect(const AAddress: string; ATimeoutMs: Cardinal;
  AKeepAliveSeconds: Cardinal; AVerifyPeer: Boolean): TPipeEndpoint;

/// Ainda nao implementado: exige handshake fora da thread de accept (T1) e o
/// lado servidor dos backends (T2/T3), que nao existe no codigo herdado do
/// pascal-amqp-faa — aquele projeto e' cliente e nunca aceita conexao.
function TlsPipeCreateListener(const AAddress: string;
  AKeepAliveSeconds: Cardinal): TPipeListener;

implementation

uses
  Pipes.Transport.Tcp
  {$IFDEF PIPES_WINDOWS}
  , Pipes.Transport.Schannel
  {$ENDIF}
  {$IFDEF PIPES_OPENSSL}
  , Pipes.Transport.OpenSSL
  {$ENDIF};

{ TPipeTlsEndpoint }

constructor TPipeTlsEndpoint.Create(AInner: TPipeEndpoint;
  const ATargetName: string; AVerifyPeer: Boolean);
var
  LRaw: TPipeEndpointStream;
begin
  inherited Create;
  FInner := AInner; // posse assumida JA: se o handshake abaixo levantar, o
                    // destructor desta classe e' chamado e libera AInner — o
                    // chamador nao deve liberar nada depois de chamar Create.
  // TPipeEndpointStream nao e' dono do endpoint; o backend TLS passa a ser
  // dono DELE (nao do endpoint).
  //
  // Sem 'try/except LRaw.Free' aqui de proposito: o backend assume a posse de
  // LRaw na primeira linha do construtor dele, entao se o handshake falhar o
  // destructor DELE ja libera LRaw. Liberar aqui tambem seria double-free —
  // e' o que o cabecalho de Pipes.Transport.Schannel avisa, e o que uma versao
  // anterior deste adaptador fazia (EAccessViolation ao rejeitar certificado
  // invalido, justamente o caminho de erro que precisa funcionar).
  {$IFDEF PIPES_OPENSSL}
  LRaw := TPipeEndpointStream.Create(AInner);
  FTls := TPipeOpenSslStream.Create(LRaw, ATargetName, AVerifyPeer);
  {$ELSE}
    {$IFDEF PIPES_WINDOWS}
    LRaw := TPipeEndpointStream.Create(AInner);
    FTls := TPipeSchannelStream.Create(LRaw, ATargetName, AVerifyPeer);
    {$ELSE}
    raise EPipeTls.Create('build sem backend TLS: compile com PIPES_OPENSSL');
    {$ENDIF}
  {$ENDIF}
end;

destructor TPipeTlsEndpoint.Destroy;
begin
  // O stream TLS tenta o close_notify no proprio destructor (best-effort, ja
  // protegido la) e libera o TPipeEndpointStream. O endpoint TCP e' nosso.
  FTls.Free;
  FInner.Free;
  inherited;
end;

procedure TPipeTlsEndpoint.CloseAbort;
begin
  // Toda espera do backend TLS termina num Read/Write do endpoint de baixo:
  // abortar la desbloqueia a pilha inteira. Idempotente porque o do TCP e'.
  if Assigned(FInner) then
    FInner.CloseAbort;
end;

function TPipeTlsEndpoint.Read(var ABuffer; ACount: Integer): Integer;
begin
  Result := FTls.Read(ABuffer, ACount);
  // TStream sinaliza fim com 0; o contrato de TPipeEndpoint e' excecao.
  if Result <= 0 then
    raise EPipeClosed.Create('conexao TLS encerrada pelo par');
end;

procedure TPipeTlsEndpoint.WriteExactly(const ABuffer; ACount: Integer);
begin
  // Os backends escrevem tudo ou levantam; o laco e' rede de seguranca para
  // uma eventual escrita parcial.
  if FTls.Write(ABuffer, ACount) <> ACount then
    raise EPipeClosed.Create('escrita TLS incompleta');
end;

{ --- fabricas --- }

function TlsPipeConnect(const AAddress: string; ATimeoutMs: Cardinal;
  AKeepAliveSeconds: Cardinal; AVerifyPeer: Boolean): TPipeEndpoint;
var
  LTcp: TPipeEndpoint;
  LHost: string;
  LPort: Word;
begin
  // O host de Address e' o nome esperado no certificado (SNI + validacao).
  PipeParseHostPort(AAddress, LHost, LPort);
  LTcp := TcpPipeConnect(AAddress, ATimeoutMs, AKeepAliveSeconds);
  // Idem: TPipeTlsEndpoint.Create assume a posse de LTcp imediatamente, e o
  // destructor dele o libera se o handshake falhar. Nao ha nada a liberar aqui.
  Result := TPipeTlsEndpoint.Create(LTcp, LHost, AVerifyPeer);
end;

function TlsPipeCreateListener(const AAddress: string;
  AKeepAliveSeconds: Cardinal): TPipeListener;
begin
  Result := nil;
  raise EPipeTls.Create('servidor ptTls ainda nao implementado ' +
    '(o lado cliente ja funciona)');
end;

end.
