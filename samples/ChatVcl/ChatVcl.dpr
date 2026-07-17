program ChatVcl;

{ Chat via Named Pipes com UI (VCL no Delphi, LCL no Lazarus) a partir do
  MESMO fonte. Abra uma instancia como servidor e varias como cliente.

  Vitrine do DispatchMode = pdmMainThread: os eventos da lib chegam direto na
  thread da UI — nenhum Synchronize/Queue manual no codigo do form. }

uses
  {$IFDEF FPC}
    {$IFDEF UNIX}
  cthreads, // threads reais no Unix: sem isso os eventos/condvars da lib falham em runtime
    {$ENDIF}
  Interfaces,
  {$ENDIF}
  Forms,
  uChatMain in 'uChatMain.pas' {frmChat};

begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TfrmChat, frmChat);
  Application.Run;
end.
