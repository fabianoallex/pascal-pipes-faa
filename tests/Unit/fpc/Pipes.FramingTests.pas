unit Pipes.FramingTests;

{$mode delphi}{$H+}

{ Testes do wire format NPF1 (Pipes.Framing) e da conversao UTF-8 portatil.
  Versao FPCUnit; espelha a cobertura da versao DUnitX em tests/Unit. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  Classes,
  Pipes.Types,
  Pipes.Framing;

type
  TPipeFramingTests = class(TTestCase)
  private
    FStream: TBytesStream;
    FFrame: TPipeFrame;
    procedure DoReadFromStream;   // PipeReadFrame(FStream, 100)
    procedure DoWriteToStream;    // PipeWriteFrame(FStream, FFrame, 100)
  protected
    procedure TearDown; override;
  published
    procedure Encode_LayoutBinario;
    procedure RoundTrip_Message;
    procedure RoundTrip_RequestReply_PreservaCorrId;
    procedure RoundTrip_PayloadVazio;
    procedure RoundTrip_MultiplosFramesEmSequencia;
    procedure RoundTrip_ErrorReply_PreservaFlagEMensagem;
    procedure ReadFrame_MagicInvalido_Levanta;
    procedure ReadFrame_KindDesconhecido_Levanta;
    procedure ReadFrame_PayloadAcimaDoMaximo_Levanta;
    procedure ReadFrame_StreamTruncado_Levanta;
    procedure WriteFrame_PayloadAcimaDoMaximo_Levanta;
    procedure Utf8_RoundTripAscii;
    procedure Utf8_RoundTripNaoAscii_ViaBytes;
  end;

implementation

// Forca a sobrecarga nao-generica AssertEquals(Integer, Integer).
procedure EqualByte(AExpected: Integer; AActual: Byte);
begin
  TAssert.AssertEquals(AExpected, Integer(AActual));
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
  inherited;
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
  AssertEquals(23, Length(B));
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
  AssertTrue('kind devia ser pfkMessage', LFrame.Kind = pfkMessage);
  AssertTrue('corrId de msg devia ser 0', LFrame.CorrId = 0);
  AssertEquals(5, Length(LFrame.Payload));
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
  AssertTrue('primeiro frame devia ser request', LFrame.Kind = pfkRequest);
  AssertTrue('corrId do request nao preservado', LFrame.CorrId = 42);
  AssertEquals('ping', LFrame.PayloadAsText);

  LFrame := PipeReadFrame(FStream, 1024);
  AssertTrue('segundo frame devia ser reply', LFrame.Kind = pfkReply);
  AssertTrue('corrId do reply nao preservado', LFrame.CorrId = 42);
  AssertEquals('pong', LFrame.PayloadAsText);
end;

procedure TPipeFramingTests.RoundTrip_PayloadVazio;
var
  LFrame: TPipeFrame;
begin
  FStream := TBytesStream.Create;
  PipeWriteFrame(FStream, TPipeFrame.Msg(nil), 1024);
  FStream.Position := 0;
  LFrame := PipeReadFrame(FStream, 1024);
  AssertTrue(LFrame.Kind = pfkMessage);
  AssertEquals(0, Length(LFrame.Payload));
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
  AssertTrue(LFrame.Kind = pfkMessage);
  AssertEquals(1, Length(LFrame.Payload));

  LFrame := PipeReadFrame(FStream, 1024);
  AssertTrue(LFrame.Kind = pfkRequest);
  AssertEquals(2, Length(LFrame.Payload));
  EqualByte(20, LFrame.Payload[0]);
  EqualByte(21, LFrame.Payload[1]);

  LFrame := PipeReadFrame(FStream, 1024);
  AssertTrue(LFrame.Kind = pfkReply);
  AssertTrue(LFrame.CorrId = 7);
  AssertEquals(0, Length(LFrame.Payload));
end;

procedure TPipeFramingTests.RoundTrip_ErrorReply_PreservaFlagEMensagem;
var
  LFrame: TPipeFrame;
begin
  FStream := TBytesStream.Create;
  PipeWriteFrame(FStream, TPipeFrame.ErrorReply(7, 'falha proposital'), 1024);
  FStream.Position := 0;
  LFrame := PipeReadFrame(FStream, 1024);
  AssertTrue('kind devia ser reply', LFrame.Kind = pfkReply);
  AssertTrue('flag de erro nao preservada', LFrame.IsError);
  AssertTrue('corrId nao preservado', LFrame.CorrId = 7);
  AssertEquals('falha proposital', LFrame.PayloadAsText);
end;

procedure TPipeFramingTests.ReadFrame_MagicInvalido_Levanta;
begin
  FStream := BuildStream([Ord('X'), Ord('P'), Ord('F'), Ord('1'),
    0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0]);
  AssertException(EPipeProtocol, DoReadFromStream);
end;

procedure TPipeFramingTests.ReadFrame_KindDesconhecido_Levanta;
begin
  FStream := BuildStream([Ord('N'), Ord('P'), Ord('F'), Ord('1'),
    99, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0]);
  AssertException(EPipeProtocol, DoReadFromStream);
end;

procedure TPipeFramingTests.ReadFrame_PayloadAcimaDoMaximo_Levanta;
begin
  // length = 101, maximo do teste = 100
  FStream := BuildStream([Ord('N'), Ord('P'), Ord('F'), Ord('1'),
    0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  101, 0, 0, 0]);
  AssertException(EPipeProtocol, DoReadFromStream);
end;

procedure TPipeFramingTests.ReadFrame_StreamTruncado_Levanta;
begin
  // header anuncia 10 bytes de payload; so ha 3
  FStream := BuildStream([Ord('N'), Ord('P'), Ord('F'), Ord('1'),
    0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  10, 0, 0, 0,
    1, 2, 3]);
  AssertException(EPipeClosed, DoReadFromStream);
end;

procedure TPipeFramingTests.WriteFrame_PayloadAcimaDoMaximo_Levanta;
var
  LBig: TBytes;
begin
  SetLength(LBig, 101); // maximo do teste = 100
  FFrame := TPipeFrame.Msg(LBig);
  FStream := TBytesStream.Create;
  AssertException(EPipeProtocol, DoWriteToStream);
  AssertEquals(0, Integer(FStream.Size)); // falhou ANTES de escrever
end;

procedure TPipeFramingTests.Utf8_RoundTripAscii;
const
  S = 'named pipes 123';
begin
  AssertEquals(S, PipeUtf8Decode(PipeUtf8Encode(S)));
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
  AssertEquals(Length(LIn), Length(LOut));
  for I := 0 to High(LIn) do
    EqualByte(LIn[I], LOut[I]);
end;

initialization
  RegisterTest(TPipeFramingTests);

end.
