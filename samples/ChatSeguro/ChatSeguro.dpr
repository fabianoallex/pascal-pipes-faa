program ChatSeguro;

{ Chat sobre ptTls com mTLS, com UI (VCL no Delphi, LCL no Lazarus) a partir do
  MESMO fonte. Abra uma instancia como hub e varias como participante.

  A diferenca para o ChatVcl nao e' so' "com TLS": aqui QUEM esta na sala vem
  do certificado apresentado e validado, nao de um apelido que o participante
  digita. Trocar o combo de identidade troca o certificado — inclusive para os
  de teste que devem ser RECUSADOS ('rogue', 'selfsigned'), que e' a parte do
  sample que mostra o mTLS funcionando.

  Precisa da PKI de teste em tests/pki. }

uses
  {$IFDEF FPC}
    {$IFDEF UNIX}
  cthreads, // threads reais no Unix: sem isso os eventos/condvars da lib falham em runtime
    {$ENDIF}
  Interfaces,
  {$ENDIF}
  Forms,
  uChatSeguroMain in 'uChatSeguroMain.pas' {frmChatSeguro};

begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TfrmChatSeguro, frmChatSeguro);
  Application.Run;
end.
