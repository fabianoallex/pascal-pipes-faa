unit Pipes.Transport.Tls;

{$I pipes.inc}

{ Transporte TLS (ptTls): TCP com a sessao cifrada por cima.

  Desde a 0.4.0 o TLS e' o da pascal-common-faa (PascalCommon.Transport.Tls,
  que nasceu do codigo que vivia aqui e em Pipes.Transport.Schannel/OpenSSL):
  PcTlsWrap sobre o endpoint TCP do pipes (que mantem o laco de re-tentativa do
  connect e, no Android, o proprio socket), PcTlsListen no servidor e
  PcTlsListenOver sobre o listener Android.

  O backend e' escolhido em RUNTIME por TPipeTlsOptions.Backend. O pipes so'
  decide o que tbDefault significa: OpenSSL quando compilado com
  PIPES_OPENSSL (sempre fora do Windows), SChannel no Windows sem ele — o mesmo
  padrao de antes da 0.4.0, agora sem exigir outro build para usar o outro.

  Onde cada lado negocia (inalterado):
  - CLIENTE: dentro de PcTlsWrap, na thread de quem chamou Connect.
  - SERVIDOR: NAO no accept. O listener devolve o endpoint ainda nao
    negociado e quem chama Handshake e' a reader thread da conexao.

  As funcoes *Raw levantam EPcTransport* (contrato da common): quem traduz para
  EPipe* e' Pipes.Transport, na fronteira. TlsPipeConnect/TlsPipeCreateListener
  sao os nomes anteriores a 0.4.0, mantidos por uma versao minor. }

interface

uses
  SysUtils,
  Pipes.Types,
  PascalCommon.Transport,
  Pipes.Transport;

/// AOptions com tbDefault trocado pelo padrao do pipes (tbOpenSsl sob
/// PIPES_OPENSSL); os outros valores passam como estao.
function PipeTlsEffectiveOptions(const AOptions: TPipeTlsOptions): TPcTlsOptions;

/// Conecta via TCP (com re-tentativa ate ATimeoutMs) e faz o handshake TLS
/// como CLIENTE; o host de AAddress e' o nome validado no certificado (SNI).
function PipeTlsConnectRaw(const AAddress: string; ATimeoutMs: Cardinal;
  AKeepAliveSeconds: Cardinal;
  const AOptions: TPipeTlsOptions): TPcEndpoint;

/// Escuta com TLS; as credenciais sao carregadas agora (arquivo ou senha
/// errados levantam aqui). O handshake de cada conexao roda depois, na reader
/// thread dela (ver TPipeEndpoint.Handshake).
function PipeTlsListenRaw(const AAddress: string; AKeepAliveSeconds: Cardinal;
  const AOptions: TPipeTlsOptions): TPcListener;

/// Nomes anteriores a 0.4.0 (obsoletos; use PipeConnect/PipeCreateListener
/// com ptTls).
function TlsPipeConnect(const AAddress: string; ATimeoutMs: Cardinal;
  AKeepAliveSeconds: Cardinal;
  const AOptions: TPipeTlsOptions): TPipeEndpoint;
function TlsPipeCreateListener(const AAddress: string;
  AKeepAliveSeconds: Cardinal;
  const AOptions: TPipeTlsOptions): TPipeListener;

implementation

uses
  PascalCommon.Transport.Tls,
  Pipes.Transport.Tcp;

function PipeTlsEffectiveOptions(const AOptions: TPipeTlsOptions): TPcTlsOptions;
begin
  Result := AOptions;
  {$IFDEF PIPES_OPENSSL}
  if Result.Backend = tbDefault then
    Result.Backend := tbOpenSsl;
  {$ENDIF}
end;

// PipeTlsBackendInfo (Pipes.Types) continua sendo "o backend da ultima sessao
// TLS", vazio ate o primeiro uso, como antes da 0.4.0.
procedure NoteBackend(const AOptions: TPcTlsOptions);
begin
  PipeSetTlsBackendDetail(PcTlsBackendInfo(AOptions.Backend));
end;

function PipeTlsConnectRaw(const AAddress: string; ATimeoutMs: Cardinal;
  AKeepAliveSeconds: Cardinal;
  const AOptions: TPipeTlsOptions): TPcEndpoint;
var
  LTls: TPcTlsOptions;
  LHost: string;
  LPort: Word;
begin
  LTls := PipeTlsEffectiveOptions(AOptions);
  // Backend invalido (tbSChannel fora do Windows) falha ANTES de conectar.
  PcTlsResolveBackend(LTls.Backend);
  PipeParseHostPort(AAddress, LHost, LPort);
  // PcTlsWrap assume a posse do endpoint TCP inclusive quando o handshake
  // falha: nao ha nada a liberar aqui.
  Result := PcTlsWrap(PipeTcpConnectRaw(AAddress, ATimeoutMs,
    AKeepAliveSeconds), LHost, LTls);
  NoteBackend(LTls);
end;

function PipeTlsListenRaw(const AAddress: string; AKeepAliveSeconds: Cardinal;
  const AOptions: TPipeTlsOptions): TPcListener;
var
  LTls: TPcTlsOptions;
  {$IFNDEF PIPES_ANDROID}
  LHost: string;
  LPort: Word;
  LTcp: TPcTcpOptions;
  {$ENDIF}
begin
  LTls := PipeTlsEffectiveOptions(AOptions);
  {$IFDEF PIPES_ANDROID}
  // PcTcpListen nao existe no Android: o listener e' o do pipes, e o TLS
  // entra por cima dele.
  Result := PcTlsListenOver(PipeTcpListenRaw(AAddress, AKeepAliveSeconds),
    LTls);
  {$ELSE}
  PipeParseHostPort(AAddress, LHost, LPort);
  LTcp := Default(TPcTcpOptions);
  LTcp.KeepAliveSeconds := AKeepAliveSeconds;
  Result := PcTlsListen(LHost, LPort, LTcp, LTls);
  {$ENDIF}
  NoteBackend(LTls);
end;

function TlsPipeConnect(const AAddress: string; ATimeoutMs: Cardinal;
  AKeepAliveSeconds: Cardinal;
  const AOptions: TPipeTlsOptions): TPipeEndpoint;
begin
  Result := PipeConnect(AAddress, ATimeoutMs, ptTls, AKeepAliveSeconds,
    AOptions);
end;

function TlsPipeCreateListener(const AAddress: string;
  AKeepAliveSeconds: Cardinal;
  const AOptions: TPipeTlsOptions): TPipeListener;
begin
  Result := PipeCreateListener(AAddress, ptTls, AKeepAliveSeconds, AOptions);
end;

end.
