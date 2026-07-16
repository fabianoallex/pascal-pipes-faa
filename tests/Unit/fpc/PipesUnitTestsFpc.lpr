program PipesUnitTestsFpc;

{ Runner FPCUnit dos testes unitarios (mesma cobertura do tests/Unit/*.pas
  DUnitX/Delphi, portada para FPCUnit).

  Console (saida de texto), quando chamado com qualquer parametro:
    .\PipesUnitTestsFpc.exe --all --format=plain
  GUI (janela com arvore de testes + barra verde/vermelha), sem parametros:
    .\PipesUnitTestsFpc.exe
  Fora do Windows roda sempre em modo console (sem LCL/widgetset), com ou
  sem parametros. }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Interfaces, Forms, GuiTestRunner,
  {$ENDIF}
  Classes, consoletestrunner, testregistry,
  Pipes.ThreadingTests;

var
  ConsoleApp: TTestRunner;
begin
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
      ConsoleApp.Title := 'pascal-named-pipes-faa - testes unitarios (FPCUnit)';
      ConsoleApp.Run;
    finally
      ConsoleApp.Free;
    end;
  end;
end.
