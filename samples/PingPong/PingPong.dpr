program PingPong;

{ Ping Pong para dois jogadores em rede, com UI (VCL no Delphi, LCL no Lazarus)
  a partir do MESMO fonte.

  Abra duas instancias: numa clique "Hospedar", na outra "Entrar". Em ptLocal
  as duas ficam na mesma maquina; em ptTcp o convidado digita o endereco do
  hospedeiro e as duas podem estar em maquinas diferentes.

  Para experimentar sozinho, sem segunda janela: marque "Computador ocupa a
  vaga do convidado" e clique Hospedar.

  Vitrine de SIMULACAO CONTINUA sobre a lib: passo fixo com acumulador,
  entrada por borda / estado por nivel, e previsao no cliente entre snapshots.
  Ver o cabecalho de uPongMain.pas. }

uses
  {$IFDEF FPC}
    {$IFDEF UNIX}
  cthreads, // threads reais no Unix: sem isso os eventos/condvars da lib falham em runtime
    {$ENDIF}
  Interfaces,
  {$ENDIF}
  Forms,
  Pong.Partida in 'Pong.Partida.pas',
  Pong.Protocolo in 'Pong.Protocolo.pas',
  Pong.Ia in 'Pong.Ia.pas',
  uPongMain in 'uPongMain.pas' {frmPong};

begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TfrmPong, frmPong);
  Application.Run;
end.
