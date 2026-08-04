unit Pipes.CompressionTests;

{ Testes do envelope de compressao (Pipes.Compression). Versao DUnitX/Delphi;
  a versao FPCUnit em tests/Unit/fpc espelha a mesma cobertura. }

interface

uses
  DUnitX.TestFramework,
  SysUtils,
  Pipes.Types,
  Pipes.Framing,
  Pipes.Compression;

type
  [TestFixture]
  TPipeCompressionTests = class
  private
    procedure DoUndoCompressKindErrado;
    procedure DoInflateZipBomb;
  published
    [Test] procedure Deflate_Inflate_RoundTrip_PreservaBytes;
    [Test] procedure Deflate_Inflate_RoundTrip_PayloadVazio;
    [Test] procedure MaybeCompress_MinSizeZero_DevolveOriginalSemMudar;
    [Test] procedure MaybeCompress_AbaixoDoMinimo_DevolveOriginalSemMudar;
    [Test] procedure MaybeCompress_KindNaoElegivel_DevolveOriginalSemMudar;
    [Test] procedure MaybeCompress_PayloadCompressivel_EmpacotaEmPfkCompressed;
    [Test] procedure MaybeCompress_PayloadIncompressivel_DevolveOriginalSemMudar;
    [Test] procedure MaybeCompress_PreservaCorrId;
    [Test] procedure UndoCompress_RoundTrip_RestauraKindFlagsPayload;
    [Test] procedure UndoCompress_PreservaFlagDeErro;
    [Test] procedure UndoCompress_KindNaoCompressed_Levanta;
    [Test] procedure Inflate_ZipBomb_ExcedeLimite_Levanta;
    [Test] procedure IsCompressible_KindsCorretos;
  end;

implementation

// Idem para contagens: Length() e' NativeInt no Win64 e o AreEqual<T> generico
// nao infere T com argumentos de tipos diferentes (E2532) — mesma armadilha e
// mesmo remedio de Pipes.FramingTests.
procedure EqualInt(AExpected, AActual: Integer);
begin
  Assert.AreEqual(AExpected, AActual);
end;

// Bytes pseudo-aleatorios deterministicos (LCG proprio, sem depender de
// Random/RandSeed): dado incompressivel de proposito, para testar o
// caminho "nao compensou".
{$Q-} // LCG depende do overflow (wraparound mod 2^32) ser SILENCIOSO; com
       // overflow checking ligado (padrao no Debug do Delphi) a multiplicacao
       // levantaria EIntOverflow num calculo correto por definicao — mesma
       // armadilha do FNV-1a em Pipes.Framing.PipeGroupKeyHash.
function MakeRandomBytes(ACount: Integer; ASeed: Cardinal): TBytes;
var
  I: Integer;
  LState: Cardinal;
begin
  Result := nil;
  SetLength(Result, ACount);
  LState := ASeed;
  for I := 0 to ACount - 1 do
  begin
    LState := (LState * 1103515245 + 12345) and $7FFFFFFF;
    Result[I] := Byte(LState shr 16);
  end;
end;
{$Q+}

function MakeRepeatedBytes(ACount: Integer; AValue: Byte): TBytes;
begin
  Result := nil;
  SetLength(Result, ACount);
  if ACount > 0 then
    FillChar(Result[0], ACount, AValue);
end;

{ TPipeCompressionTests }

procedure TPipeCompressionTests.DoUndoCompressKindErrado;
begin
  PipeUndoCompress(TPipeFrame.Msg(nil), 1024);
end;

procedure TPipeCompressionTests.DoInflateZipBomb;
var
  LDeflated: TBytes;
begin
  LDeflated := PipeDeflate(MakeRepeatedBytes(1024 * 1024, 0));
  PipeInflate(LDeflated, 1000); // limite bem abaixo do 1 MB original
end;

procedure TPipeCompressionTests.Deflate_Inflate_RoundTrip_PreservaBytes;
var
  LOriginal, LDeflated, LResult: TBytes;
begin
  LOriginal := MakeRepeatedBytes(5000, 42);
  LDeflated := PipeDeflate(LOriginal);
  Assert.IsTrue(Length(LDeflated) < Length(LOriginal), 'dado repetitivo devia comprimir');
  LResult := PipeInflate(LDeflated, 1024 * 1024);
  EqualInt(Length(LOriginal), Length(LResult));
  Assert.IsTrue(CompareMem(@LOriginal[0], @LResult[0], Length(LOriginal)),
    'bytes divergem depois do round-trip deflate/inflate');
end;

procedure TPipeCompressionTests.Deflate_Inflate_RoundTrip_PayloadVazio;
var
  LDeflated, LResult: TBytes;
begin
  LDeflated := PipeDeflate(nil);
  LResult := PipeInflate(LDeflated, 1024);
  EqualInt(0, Length(LResult));
end;

procedure TPipeCompressionTests.MaybeCompress_MinSizeZero_DevolveOriginalSemMudar;
var
  LFrame, LResult: TPipeFrame;
begin
  LFrame := TPipeFrame.Msg(MakeRepeatedBytes(5000, 7));
  LResult := PipeMaybeCompress(LFrame, PIPE_COMPRESSION_DISABLED);
  Assert.IsTrue(LResult.Kind = pfkMessage, 'AMinSize=0 devia desligar a producao');
  EqualInt(Length(LFrame.Payload), Length(LResult.Payload));
end;

procedure TPipeCompressionTests.MaybeCompress_AbaixoDoMinimo_DevolveOriginalSemMudar;
var
  LFrame, LResult: TPipeFrame;
begin
  LFrame := TPipeFrame.Msg(MakeRepeatedBytes(100, 7)); // < 512
  LResult := PipeMaybeCompress(LFrame, 512);
  Assert.IsTrue(LResult.Kind = pfkMessage);
  EqualInt(100, Length(LResult.Payload));
end;

procedure TPipeCompressionTests.MaybeCompress_KindNaoElegivel_DevolveOriginalSemMudar;
var
  LFrame, LResult: TPipeFrame;
begin
  // Ping nao tem payload alem de ser kind nao-elegivel; usamos um payload
  // grande e repetitivo simulado num kind estrutural (Subscribe) so' para
  // provar que o KIND, nao o tamanho, decide.
  LFrame.Kind := pfkSubscribe;
  LFrame.Flags := 0;
  LFrame.CorrId := 0;
  LFrame.Payload := MakeRepeatedBytes(5000, 9);
  LResult := PipeMaybeCompress(LFrame, 512);
  Assert.IsTrue(LResult.Kind = pfkSubscribe, 'kind nao elegivel nunca deve virar pfkCompressed');
end;

procedure TPipeCompressionTests.MaybeCompress_PayloadCompressivel_EmpacotaEmPfkCompressed;
var
  LFrame, LResult: TPipeFrame;
begin
  LFrame := TPipeFrame.Msg(MakeRepeatedBytes(5000, 123));
  LResult := PipeMaybeCompress(LFrame, 512);
  Assert.IsTrue(LResult.Kind = pfkCompressed, 'payload compressivel acima do minimo devia empacotar');
  Assert.IsTrue(Length(LResult.Payload) < Length(LFrame.Payload),
    'envelope comprimido devia ser menor que o payload original');
end;

procedure TPipeCompressionTests.MaybeCompress_PayloadIncompressivel_DevolveOriginalSemMudar;
var
  LFrame, LResult: TPipeFrame;
begin
  LFrame := TPipeFrame.Msg(MakeRandomBytes(2000, 999));
  LResult := PipeMaybeCompress(LFrame, 512);
  Assert.IsTrue(LResult.Kind = pfkMessage,
    'dado incompressivel nao devia virar pfkCompressed (overhead nao compensa)');
  EqualInt(Length(LFrame.Payload), Length(LResult.Payload));
end;

procedure TPipeCompressionTests.MaybeCompress_PreservaCorrId;
var
  LFrame, LResult: TPipeFrame;
begin
  LFrame := TPipeFrame.Msg(MakeRepeatedBytes(5000, 1), $1122334455667788);
  LResult := PipeMaybeCompress(LFrame, 512);
  Assert.IsTrue(LResult.Kind = pfkCompressed);
  Assert.IsTrue(LResult.CorrId = $1122334455667788,
    'CorrId (hash de AGroupKey / correlacao) tem que atravessar sem mudanca');
end;

procedure TPipeCompressionTests.UndoCompress_RoundTrip_RestauraKindFlagsPayload;
var
  LOriginal, LCompressed, LRestored: TPipeFrame;
begin
  LOriginal := TPipeFrame.Request(77, MakeRepeatedBytes(5000, 55));
  LCompressed := PipeMaybeCompress(LOriginal, 512);
  Assert.IsTrue(LCompressed.Kind = pfkCompressed);
  LRestored := PipeUndoCompress(LCompressed, 1024 * 1024);
  Assert.IsTrue(LRestored.Kind = pfkRequest);
  Assert.IsTrue(LRestored.CorrId = 77);
  EqualInt(0, Integer(LRestored.Flags));
  EqualInt(Length(LOriginal.Payload), Length(LRestored.Payload));
  Assert.IsTrue(CompareMem(@LOriginal.Payload[0], @LRestored.Payload[0],
    Length(LOriginal.Payload)), 'payload divergiu depois do round-trip do envelope');
end;

procedure TPipeCompressionTests.UndoCompress_PreservaFlagDeErro;
var
  LOriginal, LCompressed, LRestored: TPipeFrame;
begin
  LOriginal := TPipeFrame.ErrorReply(9, StringOfChar('x', 2000));
  LCompressed := PipeMaybeCompress(LOriginal, 512);
  Assert.IsTrue(LCompressed.Kind = pfkCompressed);
  LRestored := PipeUndoCompress(LCompressed, 1024 * 1024);
  Assert.IsTrue(LRestored.Kind = pfkReply);
  Assert.IsTrue(LRestored.IsError, 'PIPE_FLAG_ERROR tem que sobreviver ao envelope');
  Assert.AreEqual(LOriginal.PayloadAsText, LRestored.PayloadAsText);
end;

procedure TPipeCompressionTests.UndoCompress_KindNaoCompressed_Levanta;
begin
  Assert.WillRaise(DoUndoCompressKindErrado, EArgumentException);
end;

procedure TPipeCompressionTests.Inflate_ZipBomb_ExcedeLimite_Levanta;
begin
  Assert.WillRaise(DoInflateZipBomb, EPipeProtocol);
end;

procedure TPipeCompressionTests.IsCompressible_KindsCorretos;
begin
  Assert.IsTrue(PipeIsCompressible(pfkMessage));
  Assert.IsTrue(PipeIsCompressible(pfkRequest));
  Assert.IsTrue(PipeIsCompressible(pfkReply));
  Assert.IsTrue(PipeIsCompressible(pfkPublish));
  Assert.IsFalse(PipeIsCompressible(pfkPing));
  Assert.IsFalse(PipeIsCompressible(pfkSubscribe));
  Assert.IsFalse(PipeIsCompressible(pfkUnsubscribe));
  Assert.IsFalse(PipeIsCompressible(pfkCompressed));
end;

initialization
  TDUnitX.RegisterTestFixture(TPipeCompressionTests);

end.
