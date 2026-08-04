unit Pipes.Compression;

{$I pipes.inc}

{ Envelope de compressao opcional (deflate) sobre frames NPF1 — ver o
  cabecalho de Pipes.Framing (pfkCompressed) para o layout do envelope e o
  racional de por que isto e' um KIND novo, nao um bit de Flags.

  Codec: System.ZLib no Delphi (embarcado no Windows; em Android/POSIX linka
  libz.so do proprio SO — parte do bionic no Android, presente por padrao no
  Linux desktop, nao e' dependencia nova do projeto) e paszlib/zstream no
  FPC (port Pascal puro do zlib, zero dependencia de runtime). Os dois lados
  usam o nivel de compressao DEFAULT do zlib (zcDefault/cldefault, que o
  proprio zlib documenta como equivalente a nivel 6) e janela/cabecalho
  zlib padrao — compativel entre os dois compiladores nos dois sentidos.

  Decodificacao (PipeUndoCompress) e' SEMPRE ativa, independente de
  CompressionMinSize: um peer so' PRODUZ frames comprimidos se configurado
  para isso, mas qualquer peer rodando esta unit sabe DESCOMPRIMIR assim que
  recebe um pfkCompressed — permite ligar de um lado so', ou nos dois em
  momentos diferentes do rollout, sem handshake de capacidade nenhum. }

interface

uses
  SysUtils,
  Classes,
  Pipes.Types,
  Pipes.Framing;

/// CompressionMinSize = 0 (padrao de Pipes.Base): desliga a PRODUCAO de
/// frames comprimidos. Nao afeta PipeUndoCompress.
const
  PIPE_COMPRESSION_DISABLED = 0;

/// Comprime ASource (deflate, nivel default do zlib). Sempre devolve bytes
/// validos, mesmo que o resultado seja maior que a entrada em dado ja
/// incompressivel (ex.: JPEG/PNG) — quem decide se vale a pena e'
/// PipeMaybeCompress, comparando tamanhos.
function PipeDeflate(const ASource: TBytes): TBytes;

/// Descomprime ASource. AMaxDecompressedSize limita o tamanho de SAIDA,
/// verificado DURANTE a descompressao (streaming em blocos, nao so' no
/// tamanho final) — protecao contra zip bomb: um payload comprimido pequeno
/// que descomprime para gigabytes estoura EPipeProtocol assim que o total
/// decodificado ultrapassa o limite, sem tentar alocar o resultado inteiro
/// primeiro.
function PipeInflate(const ASource: TBytes; AMaxDecompressedSize: Cardinal): TBytes;

/// Kinds candidatos a compressao: payload nao-trivial e nao-estrutural.
/// Ping nao tem payload; Subscribe/Unsubscribe/Compressed sao controle.
function PipeIsCompressible(AKind: TPipeFrameKind): Boolean;

/// Decide se comprime e devolve o frame a escrever no fio: o proprio AFrame
/// sem mudanca se nao compensar (AMinSize = PIPE_COMPRESSION_DISABLED, kind
/// nao elegivel, payload menor que AMinSize, ou o deflate NAO ficou menor
/// que o original), ou um TPipeFrame Kind=pfkCompressed encapsulando-o.
///
/// Chamar SEMPRE com o frame ORIGINAL, e usar o AFrame original (nao o
/// retorno desta funcao) para contabilizar Stats/MaxMessageSize no chamador:
/// o objetivo do envelope e' ser transparente para tudo que nao seja a
/// escrita no fio propriamente dita.
function PipeMaybeCompress(const AFrame: TPipeFrame; AMinSize: Cardinal): TPipeFrame;

/// Inverso de PipeMaybeCompress: AFrame.Kind DEVE ser pfkCompressed
/// (EArgumentException se nao for — erro de uso do chamador, nao de
/// protocolo). Devolve o frame original (Kind/Flags/Payload restaurados,
/// mesmo CorrId). AMaxDecompressedSize e' o mesmo teto de MaxMessageSize da
/// conexao (ver PipeInflate).
function PipeUndoCompress(const AFrame: TPipeFrame;
  AMaxDecompressedSize: Cardinal): TPipeFrame;

implementation

uses
  {$IFDEF FPC}
  ZStream
  {$ELSE}
  System.ZLib
  {$ENDIF};

const
  // Tamanho do bloco de leitura da descompressao em streaming: limita a
  // quanto o total pode passar de AMaxDecompressedSize antes de a checagem
  // pegar (no maximo um bloco de sobra), sem exigir leitura byte a byte.
  INFLATE_CHUNK = 65536;

function PipeDeflate(const ASource: TBytes): TBytes;
var
  LOut: TMemoryStream;
  LComp: {$IFDEF FPC}TCompressionStream{$ELSE}TZCompressionStream{$ENDIF};
begin
  LOut := TMemoryStream.Create;
  try
    {$IFDEF FPC}
    LComp := TCompressionStream.Create(cldefault, LOut);
    {$ELSE}
    LComp := TZCompressionStream.Create(LOut, zcDefault, 15);
    {$ENDIF}
    try
      if Length(ASource) > 0 then
        LComp.WriteBuffer(ASource[0], Length(ASource));
    finally
      // O destructor dos dois lados faz o Z_FINISH (flush) e libera o
      // z_stream — e' aqui que os bytes de fato chegam em LOut.
      LComp.Free;
    end;
    Result := nil;
    SetLength(Result, LOut.Size);
    if LOut.Size > 0 then
    begin
      LOut.Position := 0;
      LOut.ReadBuffer(Result[0], LOut.Size);
    end;
  finally
    LOut.Free;
  end;
end;

function PipeInflate(const ASource: TBytes; AMaxDecompressedSize: Cardinal): TBytes;
var
  LIn, LOut: TMemoryStream;
  LDecomp: {$IFDEF FPC}TDecompressionStream{$ELSE}TZDecompressionStream{$ENDIF};
  LBuf: array[0..INFLATE_CHUNK - 1] of Byte;
  LRead: Longint;
  LTotal: UInt64;
begin
  LIn := TMemoryStream.Create;
  LOut := TMemoryStream.Create;
  try
    if Length(ASource) > 0 then
      LIn.WriteBuffer(ASource[0], Length(ASource));
    LIn.Position := 0;
    {$IFDEF FPC}
    LDecomp := TDecompressionStream.Create(LIn);
    {$ELSE}
    LDecomp := TZDecompressionStream.Create(LIn);
    {$ENDIF}
    try
      LTotal := 0;
      repeat
        LRead := LDecomp.Read(LBuf[0], INFLATE_CHUNK);
        if LRead > 0 then
        begin
          Inc(LTotal, UInt64(LRead));
          if LTotal > AMaxDecompressedSize then
            raise EPipeProtocol.CreateFmt(
              'payload descomprimido excede o maximo configurado (%u)',
              [AMaxDecompressedSize]);
          LOut.WriteBuffer(LBuf[0], LRead);
        end;
      until LRead <= 0;
    finally
      LDecomp.Free;
    end;
    Result := nil;
    SetLength(Result, LOut.Size);
    if LOut.Size > 0 then
    begin
      LOut.Position := 0;
      LOut.ReadBuffer(Result[0], LOut.Size);
    end;
  finally
    LIn.Free;
    LOut.Free;
  end;
end;

function PipeIsCompressible(AKind: TPipeFrameKind): Boolean;
begin
  Result := AKind in [pfkMessage, pfkRequest, pfkReply, pfkPublish];
end;

function PipeMaybeCompress(const AFrame: TPipeFrame; AMinSize: Cardinal): TPipeFrame;
var
  LDeflated: TBytes;
begin
  Result := AFrame;
  if (AMinSize = PIPE_COMPRESSION_DISABLED) or not PipeIsCompressible(AFrame.Kind) then
    Exit;
  if Cardinal(Length(AFrame.Payload)) < AMinSize then
    Exit;
  LDeflated := PipeDeflate(AFrame.Payload);
  if Length(LDeflated) >= Length(AFrame.Payload) then
    Exit; // nao compensou (dado ja incompressivel) — sai cru
  Result.Kind := pfkCompressed;
  Result.Flags := 0;
  Result.CorrId := AFrame.CorrId;
  SetLength(Result.Payload, 2 + Length(LDeflated));
  Result.Payload[0] := Ord(AFrame.Kind);
  Result.Payload[1] := AFrame.Flags;
  if Length(LDeflated) > 0 then
    Move(LDeflated[0], Result.Payload[2], Length(LDeflated));
end;

function PipeUndoCompress(const AFrame: TPipeFrame;
  AMaxDecompressedSize: Cardinal): TPipeFrame;
var
  LOrigKind: Byte;
  LDeflated: TBytes;
begin
  if AFrame.Kind <> pfkCompressed then
    raise EArgumentException.Create('PipeUndoCompress exige um frame pfkCompressed');
  if Length(AFrame.Payload) < 2 then
    raise EPipeProtocol.Create('envelope pfkCompressed menor que o minimo (2 bytes)');
  LOrigKind := AFrame.Payload[0];
  if LOrigKind > Ord(High(TPipeFrameKind)) then
    raise EPipeProtocol.CreateFmt(
      'envelope pfkCompressed com kind original desconhecido (%d)', [LOrigKind]);
  Result.Kind := TPipeFrameKind(LOrigKind);
  Result.Flags := AFrame.Payload[1];
  Result.CorrId := AFrame.CorrId;
  SetLength(LDeflated, Length(AFrame.Payload) - 2);
  if Length(LDeflated) > 0 then
    Move(AFrame.Payload[2], LDeflated[0], Length(LDeflated));
  Result.Payload := PipeInflate(LDeflated, AMaxDecompressedSize);
end;

end.
