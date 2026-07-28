program PontosECaixas;

{ Pontos e Caixas (dots and boxes) para dois jogadores em rede, com UI (VCL no
  Delphi, LCL no Lazarus) a partir do MESMO fonte.

  Abra duas instancias: numa clique "Hospedar", na outra "Entrar". Em ptLocal
  as duas ficam na mesma maquina; em ptTcp o convidado digita o endereco do
  hospedeiro e as duas podem estar em maquinas diferentes.

  Vitrine de SERVIDOR AUTORITATIVO (o hospedeiro e' o unico que aplica regra)
  e de RECONEXAO COM IDENTIDADE (o convidado que cai volta para a MESMA vaga,
  pelo token que repete no OnConnected). Ver o cabecalho de uJogoMain.pas. }

uses
  {$IFDEF FPC}
    {$IFDEF UNIX}
  cthreads, // threads reais no Unix: sem isso os eventos/condvars da lib falham em runtime
    {$ENDIF}
  Interfaces,
  {$ENDIF}
  Forms,
  Jogo.Partida in 'Jogo.Partida.pas',
  Jogo.Protocolo in 'Jogo.Protocolo.pas',
  Jogo.Ia in 'Jogo.Ia.pas',
  uJogoMain in 'uJogoMain.pas' {frmJogo};

begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TfrmJogo, frmJogo);
  Application.Run;
end.
