unit Pipes.CompressionTests;

{$mode delphi}{$H+}

{ Testes do envelope de compressao (Pipes.Compression). Versao FPCUnit;
  espelha a cobertura da versao DUnitX em tests/Unit. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  Pipes.Types,
  Pipes.Framing,
  Pipes.Compression;

type
  TPipeCompressionTests = class(TTestCase)
  private
    procedure DoUndoCompressKindErrado;
    procedure DoInflateZipBomb;
  published
    procedure Deflate_Inflate_RoundTrip_PreservaBytes;
    procedure Deflate_Inflate_RoundTrip_PayloadVazio;
    procedure MaybeCompress_MinSizeZero_DevolveOriginalSemMudar;
    procedure MaybeCompress_AbaixoDoMinimo_DevolveOriginalSemMudar;
    procedure MaybeCompress_KindNaoElegivel_DevolveOriginalSemMudar;
    procedure MaybeCompress_PayloadCompressivel_EmpacotaEmPfkCompressed;
    procedure MaybeCompress_PayloadIncompressivel_DevolveOriginalSemMudar;
    procedure MaybeCompress_PreservaCorrId;
    procedure UndoCompress_RoundTrip_RestauraKindFlagsPayload;
    procedure UndoCompress_PreservaFlagDeErro;
    procedure UndoCompress_KindNaoCompressed_Levanta;
    procedure Inflate_ZipBomb_ExcedeLimite_Levanta;
    procedure IsCompressible_KindsCorretos;
  end;

implementation

// Bytes pseudo-aleatorios deterministicos (LCG proprio, sem depender de
// Random/RandSeed): dado incompressivel de proposito, para testar o
// caminho "nao compensou".
{$Q-} // LCG depende do overflow (wraparound mod 2^32) ser SILENCIOSO; com
       // overflow checking ligado a multiplicacao levantaria EIntOverflow num
       // calculo correto por definicao — mesma armadilha do FNV-1a em
       // Pipes.Framing.PipeGroupKeyHash.
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
  AssertTrue('dado repetitivo devia comprimir', Length(LDeflated) < Length(LOriginal));
  LResult := PipeInflate(LDeflated, 1024 * 1024);
  AssertEquals(Length(LOriginal), Length(LResult));
  AssertTrue('bytes divergem depois do round-trip deflate/inflate',
    CompareMem(@LOriginal[0], @LResult[0], Length(LOriginal)));
end;

procedure TPipeCompressionTests.Deflate_Inflate_RoundTrip_PayloadVazio;
var
  LDeflated, LResult: TBytes;
begin
  LDeflated := PipeDeflate(nil);
  LResult := PipeInflate(LDeflated, 1024);
  AssertEquals(0, Length(LResult));
end;

procedure TPipeCompressionTests.MaybeCompress_MinSizeZero_DevolveOriginalSemMudar;
var
  LFrame, LResult: TPipeFrame;
begin
  LFrame := TPipeFrame.Msg(MakeRepeatedBytes(5000, 7));
  LResult := PipeMaybeCompress(LFrame, PIPE_COMPRESSION_DISABLED);
  AssertTrue('AMinSize=0 devia desligar a producao', LResult.Kind = pfkMessage);
  AssertEquals(Length(LFrame.Payload), Length(LResult.Payload));
end;

procedure TPipeCompressionTests.MaybeCompress_AbaixoDoMinimo_DevolveOriginalSemMudar;
var
  LFrame, LResult: TPipeFrame;
begin
  LFrame := TPipeFrame.Msg(MakeRepeatedBytes(100, 7)); // < 512
  LResult := PipeMaybeCompress(LFrame, 512);
  AssertTrue(LResult.Kind = pfkMessage);
  AssertEquals(100, Length(LResult.Payload));
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
  AssertTrue('kind nao elegivel nunca deve virar pfkCompressed',
    LResult.Kind = pfkSubscribe);
end;

procedure TPipeCompressionTests.MaybeCompress_PayloadCompressivel_EmpacotaEmPfkCompressed;
var
  LFrame, LResult: TPipeFrame;
begin
  LFrame := TPipeFrame.Msg(MakeRepeatedBytes(5000, 123));
  LResult := PipeMaybeCompress(LFrame, 512);
  AssertTrue('payload compressivel acima do minimo devia empacotar',
    LResult.Kind = pfkCompressed);
  AssertTrue('envelope comprimido devia ser menor que o payload original',
    Length(LResult.Payload) < Length(LFrame.Payload));
end;

procedure TPipeCompressionTests.MaybeCompress_PayloadIncompressivel_DevolveOriginalSemMudar;
var
  LFrame, LResult: TPipeFrame;
begin
  LFrame := TPipeFrame.Msg(MakeRandomBytes(2000, 999));
  LResult := PipeMaybeCompress(LFrame, 512);
  AssertTrue('dado incompressivel nao devia virar pfkCompressed (overhead nao compensa)',
    LResult.Kind = pfkMessage);
  AssertEquals(Length(LFrame.Payload), Length(LResult.Payload));
end;

procedure TPipeCompressionTests.MaybeCompress_PreservaCorrId;
var
  LFrame, LResult: TPipeFrame;
begin
  LFrame := TPipeFrame.Msg(MakeRepeatedBytes(5000, 1), $1122334455667788);
  LResult := PipeMaybeCompress(LFrame, 512);
  AssertTrue(LResult.Kind = pfkCompressed);
  AssertTrue('CorrId (hash de AGroupKey / correlacao) tem que atravessar sem mudanca',
    LResult.CorrId = $1122334455667788);
end;

procedure TPipeCompressionTests.UndoCompress_RoundTrip_RestauraKindFlagsPayload;
var
  LOriginal, LCompressed, LRestored: TPipeFrame;
begin
  LOriginal := TPipeFrame.Request(77, MakeRepeatedBytes(5000, 55));
  LCompressed := PipeMaybeCompress(LOriginal, 512);
  AssertTrue(LCompressed.Kind = pfkCompressed);
  LRestored := PipeUndoCompress(LCompressed, 1024 * 1024);
  AssertTrue(LRestored.Kind = pfkRequest);
  AssertTrue(LRestored.CorrId = 77);
  AssertEquals(0, Integer(LRestored.Flags));
  AssertEquals(Length(LOriginal.Payload), Length(LRestored.Payload));
  AssertTrue('payload divergiu depois do round-trip do envelope',
    CompareMem(@LOriginal.Payload[0], @LRestored.Payload[0], Length(LOriginal.Payload)));
end;

procedure TPipeCompressionTests.UndoCompress_PreservaFlagDeErro;
var
  LOriginal, LCompressed, LRestored: TPipeFrame;
begin
  LOriginal := TPipeFrame.ErrorReply(9, StringOfChar('x', 2000));
  LCompressed := PipeMaybeCompress(LOriginal, 512);
  AssertTrue(LCompressed.Kind = pfkCompressed);
  LRestored := PipeUndoCompress(LCompressed, 1024 * 1024);
  AssertTrue(LRestored.Kind = pfkReply);
  AssertTrue('PIPE_FLAG_ERROR tem que sobreviver ao envelope', LRestored.IsError);
  AssertEquals(LOriginal.PayloadAsText, LRestored.PayloadAsText);
end;

procedure TPipeCompressionTests.UndoCompress_KindNaoCompressed_Levanta;
begin
  AssertException(EArgumentException, DoUndoCompressKindErrado);
end;

procedure TPipeCompressionTests.Inflate_ZipBomb_ExcedeLimite_Levanta;
begin
  AssertException(EPipeProtocol, DoInflateZipBomb);
end;

procedure TPipeCompressionTests.IsCompressible_KindsCorretos;
begin
  AssertTrue(PipeIsCompressible(pfkMessage));
  AssertTrue(PipeIsCompressible(pfkRequest));
  AssertTrue(PipeIsCompressible(pfkReply));
  AssertTrue(PipeIsCompressible(pfkPublish));
  AssertFalse(PipeIsCompressible(pfkPing));
  AssertFalse(PipeIsCompressible(pfkSubscribe));
  AssertFalse(PipeIsCompressible(pfkUnsubscribe));
  AssertFalse(PipeIsCompressible(pfkCompressed));
end;

initialization
  RegisterTest(TPipeCompressionTests);

end.
