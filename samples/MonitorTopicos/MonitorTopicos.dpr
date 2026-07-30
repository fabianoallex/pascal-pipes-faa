program MonitorTopicos;

{ Explorador de pub/sub com UI (VCL no Delphi, LCL no Lazarus) a partir do MESMO
  fonte. Uma janela hospeda, as outras entram; serve de ferramenta para depurar
  o pub/sub de qualquer app feito com a lib.

  O racional do sample — o que ele mostra e os outros nao — esta no cabecalho de
  uMonitorMain.pas.

  Roteiro de 2 minutos:
    1. Janela A: Hospedar. Janela B e C: Entrar.
    2. Em B e C: Assinar 'caixa.#'.
    3. Em A: Publicar em 'caixa.3.status' -> chega nas duas.
    4. Em A: marque RelayClientPublish. Em B: Publicar -> C recebe.
       Desmarque em A e publique de novo em B -> C nao recebe mais.
    5. Em A: Publicar com 'reter' marcado. Feche C, abra outra janela, Entrar,
       Assinar 'caixa.#' -> o valor chega marcado 'ret', sem ninguem publicar.
    6. Em A: MaxSubscriptions = 1, Aplicar. Em B: assine um segundo filtro ->
       recusado, com a mensagem aparecendo nas DUAS janelas.
    7. Em B: Assinar 'caixa*' -> recusado aqui mesmo, sem ir ao servidor.

  Compila nos dois mundos a partir do MESMO fonte:
    FPC:    lazbuild MonitorTopicos.lpi
    Delphi: abrir MonitorTopicos.dproj no IDE }

uses
  {$IFDEF FPC}
    {$IFDEF UNIX}
  cthreads, // threads reais no Unix: sem isso os eventos/condvars da lib falham
    {$ENDIF}
  Interfaces,
  {$ENDIF}
  Forms,
  uMonitorMain in 'uMonitorMain.pas' {frmMonitor};

begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  Application.Initialize;
  {$IFNDEF FPC}
  Application.MainFormOnTaskbar := True;
  {$ENDIF}
  Application.CreateForm(TfrmMonitor, frmMonitor);
  Application.Run;
end.
