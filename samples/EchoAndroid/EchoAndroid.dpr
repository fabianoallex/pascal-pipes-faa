program EchoAndroid;

{ Cliente Android (FMX) do EchoServer: conecta por ptTcp ou ptTls, manda texto
  e mostra a resposta. E' o sample do milestone A1/A2.

  Do outro lado roda o samples\EchoServer\EchoServer.exe (Windows) ou o
  equivalente FPC no Linux, com Transport := ptTcp e Address := '*:5300'.

  Ver LEIA-ME.md para o que precisa estar no manifesto (permissao INTERNET) e
  para o empacotamento das libs do OpenSSL quando se usa ptTls. }

uses
  System.StartUpCopy,
  FMX.Forms,
  uEchoAndroidMain in 'uEchoAndroidMain.pas' {frmEchoAndroid};

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TfrmEchoAndroid, frmEchoAndroid);
  Application.Run;
end.
