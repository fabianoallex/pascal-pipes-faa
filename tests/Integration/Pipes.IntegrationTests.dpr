program Pipes.IntegrationTests;

{$APPTYPE CONSOLE}
{$STRONGLINKTYPES ON}

uses
  System.SysUtils,
  DUnitX.Loggers.Console,
  DUnitX.Loggers.Xml.NUnit,
  DUnitX.TestFramework,
  Pipes.Threading in '..\..\src\Pipes.Threading.pas',
  Pipes.Types in '..\..\src\Pipes.Types.pas',
  Pipes.Framing in '..\..\src\Pipes.Framing.pas',
  Pipes.Transport in '..\..\src\Pipes.Transport.pas',
  Pipes.Transport.Windows in '..\..\src\Pipes.Transport.Windows.pas',
  Pipes.Transport.Tcp in '..\..\src\Pipes.Transport.Tcp.pas',
  Pipes.Transport.Schannel in '..\..\src\Pipes.Transport.Schannel.pas',
  Pipes.Transport.Tls in '..\..\src\Pipes.Transport.Tls.pas',
  Pipes.Base in '..\..\src\Pipes.Base.pas',
  Pipes.Server in '..\..\src\Pipes.Server.pas',
  Pipes.Client in '..\..\src\Pipes.Client.pas',
  Pipes.TransportTests in 'Pipes.TransportTests.pas',
  Pipes.EndToEndTests in 'Pipes.EndToEndTests.pas',
  Pipes.StressTests in 'Pipes.StressTests.pas';

var
  runner: ITestRunner;
  results: IRunResults;
  logger: ITestLogger;
  nunitLogger: ITestLogger;
begin
  ReportMemoryLeaksOnShutdown := True;
  try
    TDUnitX.CheckCommandLine;

    if TDUnitX.Options.Include = '' then
      TDUnitX.Options.Include := '.';

    runner := TDUnitX.CreateRunner;
    runner.UseRTTI := True;
    runner.FailsOnNoAsserts := False;

    if TDUnitX.Options.ConsoleMode <> TDunitXConsoleMode.Off then
    begin
      logger := TDUnitXConsoleLogger.Create(
        TDUnitX.Options.ConsoleMode = TDunitXConsoleMode.Quiet);
      runner.AddLogger(logger);
    end;

    nunitLogger := TDUnitXXMLNUnitFileLogger.Create(TDUnitX.Options.XMLOutputFile);
    runner.AddLogger(nunitLogger);

    results := runner.Execute;

    if not results.AllPassed then
      System.ExitCode := EXIT_ERRORS;

    if (TDUnitX.Options.ExitBehavior = TDUnitXExitBehavior.Pause) and IsConsole then
    begin
      System.Write('Done.. press <Enter> key to quit.');
      System.Readln;
    end;
  except
    on E: Exception do
      System.Writeln(E.ClassName, ': ', E.Message);
  end;
end.
