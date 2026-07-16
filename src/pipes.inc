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
