program TransferenciaArquivos;

{ Transferencia de arquivos via Named Pipes com UI (VCL no Delphi, LCL no
  Lazarus) a partir do MESMO fonte. Abra uma instancia como servidor e outra
  como cliente, no mesmo nome de pipe.

  Vitrine do CompressionMinSize (Pipes.Compression) e dos campos Wire de
  Stats: o cliente mostra a economia de banda de cada arquivo enviado
  (BytesSentWire vs BytesSent), e o servidor mostra a mesma economia do lado
  de quem SO RECEBE (ConnectionStats.BytesReceivedWire) — sem precisar saber
  se aquele arquivo especifico chegou comprimido, o que e' opaco por design. }

uses
  {$IFDEF FPC}
    {$IFDEF UNIX}
  cthreads, // threads reais no Unix: sem isso os eventos/condvars da lib falham em runtime
    {$ENDIF}
  Interfaces,
  {$ENDIF}
  Forms,
  uTransferMain in 'uTransferMain.pas' {frmTransfer};

begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TfrmTransfer, frmTransfer);
  Application.Run;
end.
