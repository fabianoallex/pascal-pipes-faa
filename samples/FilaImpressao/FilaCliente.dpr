program FilaCliente;

{ Dispara N jobs em sequencia (fire-and-forget, SendText) o mais rapido
  possivel, sem esperar resposta — e' o gerador de carga do sample
  FilaImpressao: ver FilaServidor.dpr para a demonstracao de pdmSerialized
  vs pdmPool.

  Uso: FilaCliente [nome-do-pipe] [quantidade=20]
  Compila nos dois mundos a partir do MESMO fonte:
    FPC:    fpc -MDelphi -Sh -Fu..\..\src FilaCliente.dpr  (ou lazbuild)
    Delphi: abrir FilaCliente.dproj no IDE }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ELSE}
  {$APPTYPE CONSOLE}
{$ENDIF}

uses
  {$IFDEF FPC}
    {$IFDEF UNIX}
  cthreads,
    {$ENDIF}
  {$ENDIF}
  SysUtils,
  Pipes.Client;

var
  Client: TNamedPipeClient;
  PipeName: string;
  Quantidade, I: Integer;
begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  if ParamCount >= 1 then
    PipeName := ParamStr(1)
  else
    PipeName := 'pipes_faa_fila';
  Quantidade := 20;
  if ParamCount >= 2 then
    Quantidade := StrToIntDef(ParamStr(2), 20);

  Client := TNamedPipeClient.Create(PipeName);
  try
    Writeln('conectando em "', PipeName, '"...');
    Client.Connect(3000);
    Writeln('conectado. disparando ', Quantidade, ' jobs...');
    for I := 1 to Quantidade do
      Client.SendText(IntToStr(I)); // sem esperar: fire-and-forget
    Writeln(Quantidade, ' jobs enviados. veja a ordem de conclusao no FilaServidor.');
    Client.Disconnect;
  finally
    Client.Free;
  end;
end.
