unit Pipes.FramingTests;

{ Testes do wire format NPF1 (Pipes.Framing) e da conversao UTF-8 portatil.
  Versao DUnitX/Delphi; a versao FPCUnit em tests/Unit/fpc espelha a mesma
  cobertura. }

interface

uses
  DUnitX.TestFramework,
  SysUtils,
  Classes,
  Pipes.Types,
  Pipes.Framing;

type
  [TestFixture]
  TPipeFramingTests = class
  private
    FStream: TBytesStream;
    FFrame: TPipeFrame;
    procedure DoReadFromStream;   // PipeReadFrame(FStream, 100)
    procedure DoWriteToStream;    // PipeWriteFrame(FStream, FFrame, 100)
  public
    [TearDown] procedure TearDown;
  published
    [Test] procedure Encode_LayoutBinario;
    [Test] procedure RoundTrip_Message;
    [Test] procedure RoundTrip_RequestReply_PreservaCorrId;
    [Test] procedure RoundTrip_PayloadVazio;
    [Test] procedure RoundTrip_MultiplosFramesEmSequencia;
    [Test] procedure RoundTrip_ErrorReply_PreservaFlagEMensagem;
    [Test] procedure ReadFrame_MagicInvalido_Levanta;
    [Test] procedure ReadFrame_KindDesconhecido_Levanta;
    [Test] procedure ReadFrame_PayloadAcimaDoMaximo_Levanta;
    [Test] procedure ReadFrame_StreamTruncado_Levanta;
    [Test] procedure WriteFrame_PayloadAcimaDoMaximo_Levanta;
    [Test] procedure Utf8_RoundTripAscii;
    [Test] procedure Utf8_RoundTripNaoAscii_ViaBytes;
  end;

implementation

// Compara Byte como Integer (evita ambiguidade de sobrecargas genericas).
procedure EqualByte(AExpected: Integer; AActual: Byte);
begin
  Assert.AreEqual(AExpected, Integer(AActual));
end;

// Idem para contagens: Length() e' NativeInt no Win64 e o AreEqual<T> generico
// nao infere T com argumentos de tipos diferentes (E2532).
procedure EqualInt(AExpected, AActual: Integer);
begin
  Assert.AreEqual(AExpected, AActual);
end;

function MakeBytes(const AValues: array of Byte): TBytes;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(AValues));
  for I := 0 to High(AValues) do
    Result[I] := AValues[I];
end;

// Stream posicionado no inicio, contendo os bytes dados.
function BuildStream(const ABytes: array of Byte): TBytesStream;
var
  LTmp: TBytes;
begin
  LTmp := MakeBytes(ABytes);
  Result := TBytesStream.Create(LTmp);
  Result.Position := 0;
end;

{ TPipeFramingTests }

procedure TPipeFramingTests.TearDown;
begin
  FreeAndNil(FStream);
end;

procedure TPipeFramingTests.DoReadFromStream;
begin
  PipeReadFrame(FStream, 100);
end;

procedure TPipeFramingTests.DoWriteToStream;
begin
  PipeWriteFrame(FStream, FFrame, 100);
end;

procedure TPipeFramingTests.Encode_LayoutBinario;
var
  B: TBytes;
begin
  B := PipeEncodeFrame(TPipeFrame.Request(UInt64($1122334455667788),
    MakeBytes([$AA, $BB, $CC])));
  EqualInt(23, Length(B));
  // magic 'NPF1'
  EqualByte(Ord('N'), B[0]);
  EqualByte(Ord('P'), B[1]);
  EqualByte(Ord('F'), B[2]);
  EqualByte(Ord('1'), B[3]);
  // kind=request, flags/reserved zerados
  EqualByte(1, B[4]);
  EqualByte(0, B[5]);
  EqualByte(0, B[6]);
  EqualByte(0, B[7]);
  // corrId little-endian
  EqualByte($88, B[8]);
  EqualByte($77, B[9]);
  EqualByte($66, B[10]);
  EqualByte($55, B[11]);
  EqualByte($44, B[12]);
  EqualByte($33, B[13]);
  EqualByte($22, B[14]);
  EqualByte($11, B[15]);
  // length little-endian
  EqualByte(3, B[16]);
  EqualByte(0, B[17]);
  EqualByte(0, B[18]);
  EqualByte(0, B[19]);
  // payload
  EqualByte($AA, B[20]);
  EqualByte($BB, B[21]);
  EqualByte($CC, B[22]);
end;

procedure TPipeFramingTests.RoundTrip_Message;
var
  LFrame: TPipeFrame;
  I: Integer;
begin
  FStream := TBytesStream.Create;
  PipeWriteFrame(FStream, TPipeFrame.Msg(MakeBytes([1, 2, 3, 4, 5])), 1024);
  FStream.Position := 0;
  LFrame := PipeReadFrame(FStream, 1024);
  Assert.IsTrue(LFrame.Kind = pfkMessage, 'kind devia ser pfkMessage');
  Assert.IsTrue(LFrame.CorrId = 0, 'corrId de msg devia ser 0');
  EqualInt(5, Length(LFrame.Payload));
  for I := 0 to 4 do
    EqualByte(I + 1, LFrame.Payload[I]);
end;

procedure TPipeFramingTests.RoundTrip_RequestReply_PreservaCorrId;
var
  LFrame: TPipeFrame;
begin
  FStream := TBytesStream.Create;
  PipeWriteFrame(FStream, TPipeFrame.Request(42, PipeUtf8Encode('ping')), 1024);
  PipeWriteFrame(FStream, TPipeFrame.Reply(42, PipeUtf8Encode('pong')), 1024);
  FStream.Position := 0;

  LFrame := PipeReadFrame(FStream, 1024);
  Assert.IsTrue(LFrame.Kind = pfkRequest, 'primeiro frame devia ser request');
  Assert.IsTrue(LFrame.CorrId = 42, 'corrId do request nao preservado');
  Assert.AreEqual('ping', LFrame.PayloadAsText);

  LFrame := PipeReadFrame(FStream, 1024);
  Assert.IsTrue(LFrame.Kind = pfkReply, 'segundo frame devia ser reply');
  Assert.IsTrue(LFrame.CorrId = 42, 'corrId do reply nao preservado');
  Assert.AreEqual('pong', LFrame.PayloadAsText);
end;

procedure TPipeFramingTests.RoundTrip_PayloadVazio;
var
  LFrame: TPipeFrame;
begin
  FStream := TBytesStream.Create;
  PipeWriteFrame(FStream, TPipeFrame.Msg(nil), 1024);
  FStream.Position := 0;
  LFrame := PipeReadFrame(FStream, 1024);
  Assert.IsTrue(LFrame.Kind = pfkMessage);
  EqualInt(0, Length(LFrame.Payload));
end;

procedure TPipeFramingTests.RoundTrip_MultiplosFramesEmSequencia;
var
  LFrame: TPipeFrame;
begin
  FStream := TBytesStream.Create;
  PipeWriteFrame(FStream, TPipeFrame.Msg(MakeBytes([10])), 1024);
  PipeWriteFrame(FStream, TPipeFrame.Request(7, MakeBytes([20, 21])), 1024);
  PipeWriteFrame(FStream, TPipeFrame.Reply(7, nil), 1024);
  FStream.Position := 0;

  LFrame := PipeReadFrame(FStream, 1024);
  Assert.IsTrue(LFrame.Kind = pfkMessage);
  EqualInt(1, Length(LFrame.Payload));

  LFrame := PipeReadFrame(FStream, 1024);
  Assert.IsTrue(LFrame.Kind = pfkRequest);
  EqualInt(2, Length(LFrame.Payload));
  EqualByte(20, LFrame.Payload[0]);
  EqualByte(21, LFrame.Payload[1]);

  LFrame := PipeReadFrame(FStream, 1024);
  Assert.IsTrue(LFrame.Kind = pfkReply);
  Assert.IsTrue(LFrame.CorrId = 7);
  EqualInt(0, Length(LFrame.Payload));
end;

procedure TPipeFramingTests.RoundTrip_ErrorReply_PreservaFlagEMensagem;
var
  LFrame: TPipeFrame;
begin
  FStream := TBytesStream.Create;
  PipeWriteFrame(FStream, TPipeFrame.ErrorReply(7, 'falha proposital'), 1024);
  FStream.Position := 0;
  LFrame := PipeReadFrame(FStream, 1024);
  Assert.IsTrue(LFrame.Kind = pfkReply, 'kind devia ser reply');
  Assert.IsTrue(LFrame.IsError, 'flag de erro nao preservada');
  Assert.IsTrue(LFrame.CorrId = 7, 'corrId nao preservado');
  Assert.AreEqual('falha proposital', LFrame.PayloadAsText);
end;

procedure TPipeFramingTests.ReadFrame_MagicInvalido_Levanta;
begin
  FStream := BuildStream([Ord('X'), Ord('P'), Ord('F'), Ord('1'),
    0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0]);
  Assert.WillRaise(DoReadFromStream, EPipeProtocol);
end;

procedure TPipeFramingTests.ReadFrame_KindDesconhecido_Levanta;
begin
  FStream := BuildStream([Ord('N'), Ord('P'), Ord('F'), Ord('1'),
    99, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0]);
  Assert.WillRaise(DoReadFromStream, EPipeProtocol);
end;

procedure TPipeFramingTests.ReadFrame_PayloadAcimaDoMaximo_Levanta;
begin
  // length = 101, maximo do teste = 100
  FStream := BuildStream([Ord('N'), Ord('P'), Ord('F'), Ord('1'),
    0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  101, 0, 0, 0]);
  Assert.WillRaise(DoReadFromStream, EPipeProtocol);
end;

procedure TPipeFramingTests.ReadFrame_StreamTruncado_Levanta;
begin
  // header anuncia 10 bytes de payload; so ha 3
  FStream := BuildStream([Ord('N'), Ord('P'), Ord('F'), Ord('1'),
    0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  10, 0, 0, 0,
    1, 2, 3]);
  Assert.WillRaise(DoReadFromStream, EPipeClosed);
end;

procedure TPipeFramingTests.WriteFrame_PayloadAcimaDoMaximo_Levanta;
var
  LBig: TBytes;
begin
  SetLength(LBig, 101); // maximo do teste = 100
  FFrame := TPipeFrame.Msg(LBig);
  FStream := TBytesStream.Create;
  Assert.WillRaise(DoWriteToStream, EPipeProtocol);
  Assert.AreEqual(Int64(0), FStream.Size, 'falhou mas escreveu bytes no stream');
end;

procedure TPipeFramingTests.Utf8_RoundTripAscii;
const
  S = 'named pipes 123';
begin
  Assert.AreEqual(S, PipeUtf8Decode(PipeUtf8Encode(S)));
end;

procedure TPipeFramingTests.Utf8_RoundTripNaoAscii_ViaBytes;
var
  LIn, LOut: TBytes;
  I: Integer;
begin
  // 'e' agudo (C3 A9), c-cedilha (C3 A7) e euro (E2 82 AC) em UTF-8; construido
  // por bytes para nao depender do encoding do arquivo-fonte.
  LIn := MakeBytes([$C3, $A9, $C3, $A7, $E2, $82, $AC]);
  LOut := PipeUtf8Encode(PipeUtf8Decode(LIn));
  Assert.AreEqual(Length(LIn), Length(LOut));
  for I := 0 to High(LIn) do
    EqualByte(LIn[I], LOut[I]);
end;

initialization
  TDUnitX.RegisterTestFixture(TPipeFramingTests);

end.
