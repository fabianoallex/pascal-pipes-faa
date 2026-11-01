unit Pipes.Transport.Tcp;

{$I pipes.inc}

{ Transporte TCP (ptTcp). Desde a 0.4.0 o socket e' o da pascal-common-faa
  (PcTcpConnect/PcTcpListen em PascalCommon.Transport.Tcp, que nasceu do
  codigo que vivia aqui); esta unit ficou com o que e' POLITICA do pipes:

  - O laco de re-tentativa do connect (docs/transport-design.md da common,
    decisao T5). PcTcpConnect tenta cada endereco do nome UMA vez; aqui se
    insiste ate ATimeoutMs enquanto a recusa for "ninguem escuta"
    (EPcTransportRefused) — o servidor ainda subindo ou reiniciando, que e' o
    que da a Connect(timeout) a mesma semantica do transporte local. Nome que
    nao resolve e qualquer outro erro sobem na hora, como antes.
  - O endereco no formato do pipes ('host:porta', '*', e o IPv6 sem colchetes
    que PipeParseHostPort ainda aceita).
  - Android: PcTcpConnect/PcTcpListen nao existem la (o ramo POSIX da common e'
    FPC-only, e o addrinfo do bionic tem outro layout), entao o socket vem de
    Pipes.Transport.Android, que continua sendo do pipes (T4).

  As funcoes *Raw levantam EPcTransport* (contrato da common): quem traduz para
  EPipe* e' Pipes.Transport, na fronteira. TcpPipeConnect/TcpPipeCreateListener
  sao os nomes anteriores a 0.4.0, mantidos por uma versao minor; devolvem a
  fachada de Pipes.Transport, com excecoes EPipe*.

  Seguranca: diferente de ptLocal, TCP nao herda controle de acesso do SO (nem
  ACL do Windows, nem permissao de arquivo do UDS). Um listener em 0.0.0.0
  aceita qualquer um que alcance a porta — autenticar e' responsabilidade da
  aplicacao (ou do mTLS). }

interface

uses
  SysUtils,
  Pipes.Types,
  PascalCommon.Transport,
  Pipes.Transport;

/// Conecta, re-tentando enquanto o servidor recusar, ate ATimeoutMs.
/// EPcTransportTimeout no prazo; EPcTransport/EPipeError nos demais erros.
function PipeTcpConnectRaw(const AAddress: string; ATimeoutMs: Cardinal;
  AKeepAliveSeconds: Cardinal): TPcEndpoint;

/// Escuta em AAddress ('host:porta'; '*' = todas as interfaces IPv4).
/// AKeepAliveSeconds vale para as conexoes aceitas (0 = desligado).
function PipeTcpListenRaw(const AAddress: string;
  AKeepAliveSeconds: Cardinal): TPcListener;

/// Nomes anteriores a 0.4.0 (obsoletos; use PipeConnect/PipeCreateListener
/// com ptTcp).
function TcpPipeCreateListener(const AAddress: string;
  AKeepAliveSeconds: Cardinal): TPipeListener;
function TcpPipeConnect(const AAddress: string; ATimeoutMs: Cardinal;
  AKeepAliveSeconds: Cardinal): TPipeEndpoint;

implementation

uses
  PascalCommon.Threading
  {$IFDEF PIPES_ANDROID}
  , Pipes.Transport.Android
  {$ELSE}
  , PascalCommon.Transport.Tcp
  {$ENDIF};

const
  // Espera entre tentativas enquanto o servidor recusa: curta, porque quem
  // conecta costuma estar esperando o servidor de um processo irmao subir.
  PIPE_CONNECT_RETRY_MS = 25;

function PipeTcpConnectRaw(const AAddress: string; ATimeoutMs: Cardinal;
  AKeepAliveSeconds: Cardinal): TPcEndpoint;
{$IFNDEF PIPES_ANDROID}
var
  LHost: string;
  LPort: Word;
  LOpts: TPcTcpOptions;
  LDeadline: UInt64;
  LRemaining: Int64;
{$ENDIF}
begin
  {$IFDEF PIPES_ANDROID}
  Result := AndroidTcpConnect(AAddress, ATimeoutMs, AKeepAliveSeconds);
  {$ELSE}
  PipeParseHostPort(AAddress, LHost, LPort);
  LDeadline := PcTickMs + ATimeoutMs;
  while True do
  begin
    LRemaining := Int64(LDeadline) - Int64(PcTickMs);
    // Pelo menos uma tentativa, mesmo com prazo 0. E nunca ConnectTimeoutMs
    // = 0, que na common significa "o padrao de 10 s".
    if LRemaining < 1 then
      LRemaining := 1;
    LOpts := Default(TPcTcpOptions);
    LOpts.ConnectTimeoutMs := Cardinal(LRemaining);
    LOpts.KeepAliveSeconds := AKeepAliveSeconds;
    try
      Exit(PcTcpConnect(LHost, LPort, LOpts));
    except
      // Servidor ainda nao subiu ou backlog cheio: re-tenta ate o prazo.
      on EPcTransportRefused do
        ;
      // A mensagem leva o prazo do CHAMADOR, nao o que sobrou nesta volta.
      on EPcTransportTimeout do
        raise EPcTransportTimeout.CreateFmt('timeout (%u ms) connecting to %s',
          [ATimeoutMs, AAddress]);
    end;
    if Int64(LDeadline) - Int64(PcTickMs) <= 0 then
      raise EPcTransportTimeout.CreateFmt('timeout (%u ms) connecting to %s',
        [ATimeoutMs, AAddress]);
    Sleep(PIPE_CONNECT_RETRY_MS);
  end;
  {$ENDIF}
end;

function PipeTcpListenRaw(const AAddress: string;
  AKeepAliveSeconds: Cardinal): TPcListener;
{$IFNDEF PIPES_ANDROID}
var
  LHost: string;
  LPort: Word;
  LOpts: TPcTcpOptions;
{$ENDIF}
begin
  {$IFDEF PIPES_ANDROID}
  Result := AndroidTcpCreateListener(AAddress, AKeepAliveSeconds);
  {$ELSE}
  PipeParseHostPort(AAddress, LHost, LPort);
  LOpts := Default(TPcTcpOptions);
  LOpts.KeepAliveSeconds := AKeepAliveSeconds;
  Result := PcTcpListen(LHost, LPort, LOpts);
  {$ENDIF}
end;

function TcpPipeCreateListener(const AAddress: string;
  AKeepAliveSeconds: Cardinal): TPipeListener;
begin
  Result := PipeCreateListener(AAddress, ptTcp, AKeepAliveSeconds);
end;

function TcpPipeConnect(const AAddress: string; ATimeoutMs: Cardinal;
  AKeepAliveSeconds: Cardinal): TPipeEndpoint;
begin
  Result := PipeConnect(AAddress, ATimeoutMs, ptTcp, AKeepAliveSeconds);
end;

end.
