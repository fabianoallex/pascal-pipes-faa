{ Diretivas de compilacao compartilhadas (dual Delphi / Free Pascal).

  Cada unit da lib inclui este arquivo logo apos o 'unit ...;'. No Delphi ele
  nao tem efeito alem dos defines; no FPC ativa o mode Delphi (strings longas,
  advanced records, generics estilo Delphi, type helpers).

  PIPES_WINDOWS: alvo Windows, em qualquer compilador (Delphi define
  MSWINDOWS; FPC define WINDOWS). Transporte = Named Pipes reais (overlapped).
  PIPES_POSIX: alvo Unix/Linux (FPC). Transporte = Unix Domain Sockets. }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

{$IFDEF MSWINDOWS}
  {$DEFINE PIPES_WINDOWS}
{$ENDIF}
{$IFDEF WINDOWS}
  {$IFNDEF PIPES_WINDOWS}
    {$DEFINE PIPES_WINDOWS}
  {$ENDIF}
{$ENDIF}

{$IFNDEF PIPES_WINDOWS}
  {$DEFINE PIPES_POSIX}
{$ENDIF}

{ Backend TLS ativo. PIPES_WINDOWS sozinho NAO significa Schannel: um build
  Windows com PIPES_OPENSSL usa OpenSSL nos dois lados. Definir isso aqui evita
  espalhar IFDEFs aninhados por todo o codigo de TLS.

  PIPES_OPENSSL  - opt-in; unico backend no POSIX, opcional no Windows.
  PIPES_SCHANNEL - SSPI nativo; padrao no Windows quando OpenSSL nao foi pedido.
  PIPES_TLS      - ha ALGUM backend; sem ele, ptTls nao esta disponivel. }
{$IFDEF PIPES_OPENSSL}
  {$DEFINE PIPES_TLS}
{$ELSE}
  {$IFDEF PIPES_WINDOWS}
    {$DEFINE PIPES_SCHANNEL}
    {$DEFINE PIPES_TLS}
  {$ENDIF}
{$ENDIF}
