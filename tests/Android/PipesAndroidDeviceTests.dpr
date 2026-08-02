program PipesAndroidDeviceTests;

{ Suite de device do backend Android (milestone A3).

  Nao ha par dual-compiler aqui: o FPC nao compila para Android neste projeto,
  e nao existe runner de console dentro de um APK. Entao esta e' a unica forma
  de verificar o backend — rodando no aparelho (ou emulador) e lendo o
  resultado na tela. Ver LEIA-ME.md. }

uses
  System.StartUpCopy,
  FMX.Forms,
  uDeviceTestsMain in 'uDeviceTestsMain.pas' {frmDeviceTests};

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TfrmDeviceTests, frmDeviceTests);
  Application.Run;
end.
