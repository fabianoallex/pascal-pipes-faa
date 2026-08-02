{ Diretivas de compilacao compartilhadas (dual Delphi / Free Pascal).

  Cada unit da lib inclui este arquivo logo apos o 'unit ...;'. No Delphi ele
  nao tem efeito alem dos defines; no FPC ativa o mode Delphi (strings longas,
  advanced records, generics estilo Delphi, type helpers).

  Sao TRES eixos de plataforma, mutuamente exclusivos:

  PIPES_WINDOWS: alvo Windows, em qualquer compilador (Delphi define
  MSWINDOWS; FPC define WINDOWS). Transporte local = Named Pipes reais
  (overlapped).
  PIPES_POSIX: alvo Unix/Linux **no FPC**. Transporte local = Unix Domain
  Sockets. O backend usa BaseUnix/Sockets/UnixType, units que nao existem em
  compilador nenhum da Embarcadero — por isso este define NAO cobre o Android.
  PIPES_ANDROID: alvo Android (Delphi). So ptTcp/ptTls; ptLocal esta fora de
  escopo (app Android e' single-process e o UDS esbarra em sandboxing —
  docs/ARQUITETURA.md secao 13.1). Backend sobre as units Posix.* da RTL.

  A ordem importa: Android tambem define POSIX no compilador Delphi, entao
  PIPES_ANDROID e' testado ANTES e exclui PIPES_POSIX. Sem isso um build
  Android puxaria o backend FPC-only e nem compilaria. }

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
  {$IFDEF ANDROID}
    {$DEFINE PIPES_ANDROID}
  {$ELSE}
    {$DEFINE PIPES_POSIX}
  {$ENDIF}
{$ENDIF}

{ Backend TLS ativo. PIPES_WINDOWS sozinho NAO significa Schannel: um build
  Windows com PIPES_OPENSSL usa OpenSSL nos dois lados. Definir isso aqui evita
  espalhar IFDEFs aninhados por todo o codigo de TLS.

  PIPES_OPENSSL  - unico backend no POSIX e no Android; opcional no Windows.
  PIPES_SCHANNEL - SSPI nativo; padrao no Windows quando OpenSSL nao foi pedido.
  PIPES_TLS      - ha ALGUM backend; sem ele, ptTls nao esta disponivel.

  No Android o OpenSSL e' ligado automaticamente, diferente do POSIX/FPC (onde
  e' opt-in): Schannel e' Windows-only, entao nao ha segunda opcao a escolher, e
  deixar opt-in so renderia um "build sem backend TLS" em runtime. O carregamento
  das libs e' preguicoso (primeiro uso de ptTls), entao um app Android que so use
  ptTcp nao paga nada por isto — mas quem usar ptTls precisa empacotar
  libssl.so/libcrypto.so por ABI no deployment (docs/ARQUITETURA.md secao 13.5). }
{$IFDEF PIPES_ANDROID}
  {$IFNDEF PIPES_OPENSSL}
    {$DEFINE PIPES_OPENSSL}
  {$ENDIF}
{$ENDIF}

{$IFDEF PIPES_OPENSSL}
  {$DEFINE PIPES_TLS}
{$ELSE}
  {$IFDEF PIPES_WINDOWS}
    {$DEFINE PIPES_SCHANNEL}
    {$DEFINE PIPES_TLS}
  {$ENDIF}
{$ENDIF}
