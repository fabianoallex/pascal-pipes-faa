program PipesIntegrationTestsFpc;

{ Runner FPCUnit dos testes de integracao (loopback em processo; sem
  dependencia externa).

  Console (saida de texto), quando chamado com qualquer parametro:
    .\PipesIntegrationTestsFpc.exe --all --format=plain
  GUI (janela com arvore de testes), sem parametros. }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Interfaces, Forms, GuiTestRunner,
  {$ENDIF}
  Classes, consoletestrunner, testregistry,
  Pipes.TransportTests,
  Pipes.EndToEndTests,
  Pipes.StressTests,
  Pipes.TlsTests;

var
  ConsoleApp: TTestRunner;
begin
  // Console FPC puro: DefaultSystemCodePage nao e' UTF-8 por padrao; garante
  // que as conversoes string<->UTF-8 dos testes sejam lossless.
  SetMultiByteConversionCodePage(CP_UTF8);

  {$IFDEF MSWINDOWS}
  if ParamCount = 0 then
  begin
    Application.Initialize;
    Application.CreateForm(TGUITestRunner, TestRunner);
    Application.Run;
  end
  else
  {$ENDIF}
  begin
    DefaultFormat := fPlain;
    DefaultRunAllTests := True;
    ConsoleApp := TTestRunner.Create(nil);
    try
      ConsoleApp.Initialize;
      ConsoleApp.Title := 'pascal-named-pipes-faa - testes de integracao (FPCUnit)';
      ConsoleApp.Run;
    finally
      ConsoleApp.Free;
    end;
  end;
end.
