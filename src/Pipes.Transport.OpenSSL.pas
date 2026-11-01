unit Pipes.Transport.OpenSSL;

{$I pipes.inc}

{ OBSOLETA desde a 0.4.0; sai na proxima versao minor.

  O backend OpenSSL passou para a pascal-common-faa
  (PascalCommon.Transport.OpenSSL), junto com o resto do TLS
  (docs/transport-design.md la), com os mesmos ramos de Android (nomes das
  libs e os diretorios de CA do aparelho). Esta unit ficou so' para nao
  quebrar quem a lista num uses ou num .dproj (ela so' puxa a unit nova;
  PcOpenSslAvailable/PcOpenSslInfo estao la). As classes que existiam aqui
  (TPipeOpenSslStream, TPipeOpenSslServerStream) nao tem equivalente publico.
  Para escolher o backend use TlsOptions.Backend := tbOpenSsl — no Windows nao
  e' mais preciso compilar com PIPES_OPENSSL para isso. }

interface

uses
  PascalCommon.Transport.OpenSSL;

implementation

end.
