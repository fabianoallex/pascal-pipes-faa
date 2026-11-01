unit Pipes.Transport.Schannel;

{$I pipes.inc}

{ OBSOLETA desde a 0.4.0; sai na proxima versao minor.

  O backend SChannel passou para a pascal-common-faa
  (PascalCommon.Transport.SChannel), junto com o resto do TLS
  (docs/transport-design.md la). Esta unit ficou so' para nao quebrar quem a
  lista num uses ou num .dproj (ela so' puxa a unit nova; Pascal nao
  re-exporta simbolos de um uses). As classes que
  existiam aqui (TPipeSchannelStream, TPipeSchannelServerStream) e as funcoes
  PipeSchannelLoadPfx/LoadCaStore nao tem equivalente publico — o ptTls nunca
  precisou delas fora do proprio transporte. Para escolher o backend use
  TlsOptions.Backend := tbSChannel. }

interface

{$IFDEF PIPES_WINDOWS}
uses
  PascalCommon.Transport.SChannel;
{$ENDIF}

implementation

end.
