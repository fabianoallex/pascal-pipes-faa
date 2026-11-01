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
  // So' troca o modo se ele ainda nao for Delphi: o FPC aceita UM {$MODE} por
  // unit, e os espelhos FPCUnit gerados por tools/gen_fpc_mirror.py ja trazem
  // {$mode delphi} antes do include (Pipes.TlsTests inclui este arquivo).
  {$IFNDEF FPC_DELPHI}
    {$MODE DELPHI}
  {$ENDIF}
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

{ Backend TLS PADRAO (desde a 0.4.0 o backend e' escolhido em runtime, por
  TlsOptions.Backend; ver TPipeTlsOptions em Pipes.Types). Os dois backends
  vem da pascal-common-faa: no Windows ambos estao sempre compilados, e o
  OpenSSL (libssl/libcrypto carregadas dinamicamente) nao custa nada ate o
  primeiro uso. Estes defines so' dizem qual deles tbDefault significa:

  PIPES_OPENSSL  - tbDefault = OpenSSL. Unico backend fora do Windows (por
                   isso definido automaticamente la); no Windows, opt-in com
                   -dPIPES_OPENSSL, como antes.
  PIPES_SCHANNEL - tbDefault = SChannel (SSPI nativo): Windows sem
                   PIPES_OPENSSL.
  PIPES_TLS      - sempre definido: ptTls existe em todo build. Ficou para nao
                   quebrar quem testa por ele.

  No Android quem usa ptTls precisa empacotar libssl.so/libcrypto.so por ABI
  no deployment (docs/ARQUITETURA.md secao 13.5). }
{$IFNDEF PIPES_WINDOWS}
  {$IFNDEF PIPES_OPENSSL}
    {$DEFINE PIPES_OPENSSL}
  {$ENDIF}
{$ENDIF}

{$IFNDEF PIPES_OPENSSL}
  {$DEFINE PIPES_SCHANNEL}
{$ENDIF}
{$DEFINE PIPES_TLS}
