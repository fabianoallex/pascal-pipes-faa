unit Pipes.FramingTests;

{ Testes do wire format NPF1 (Pipes.Framing) e da conversao UTF-8 portatil.
  Mestre DUnitX; o espelho FPCUnit em tests/Unit/fpc e' gerado por
  tools/gen_fpc_mirror.py. }

interface

uses
  DUnitX.TestFramework,
  Pipes.DUnitXCompat,
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
    FFrames: TArray<TPipeFrame>;
    procedure DoReadFromStream;   // PipeReadFrame(FStream, 100)
    procedure DoWriteToStream;    // PipeWriteFrame(FStream, FFrame, 100)
    procedure DoWriteFramesToStream; // PipeWriteFrames(FStream, FFrames, 100)
  public
    [TearDown] procedure TearDown;
  public
    [Test] procedure Encode_LayoutBinario;
    [Test] procedure RoundTrip_Message;
    [Test] procedure RoundTrip_RequestReply_PreservaCorrId;
    [Test] procedure RoundTrip_PayloadVazio;
    [Test] procedure RoundTrip_MultiplosFramesEmSequencia;
    [Test] procedure RoundTrip_ErrorReply_PreservaFlagEMensagem;
    [Test] procedure RoundTrip_Ping;
    [Test] procedure ReadFrame_MagicInvalido_Levanta;
    [Test] procedure ReadFrame_KindDesconhecido_Levanta;
    [Test] procedure ReadFrame_PayloadAcimaDoMaximo_Levanta;
    [Test] procedure ReadFrame_StreamTruncado_Levanta;
    [Test] procedure WriteFrame_PayloadAcimaDoMaximo_Levanta;
    [Test] procedure WriteFrames_Vazio_NaoEscreveNada;
    [Test] procedure WriteFrames_IdenticoASequenciaDeWriteFrame;
    [Test] procedure WriteFrames_RoundTrip_PreservaOrdemEConteudo;
    [Test] procedure WriteFrames_PayloadAcimaDoMaximo_LevantaSemEscreverNada;
    [Test] procedure Utf8_RoundTripAscii;
    [Test] procedure Utf8_RoundTripNaoAscii_ViaBytes;
  end;

implementation

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

procedure TPipeFramingTests.DoWriteFramesToStream;
begin
  PipeWriteFrames(FStream, FFrames, 100);
end;

procedure TPipeFramingTests.Encode_LayoutBinario;
var
  B: TBytes;
begin
  B := PipeEncodeFrame(TPipeFrame.Request(UInt64($1122334455667788),
    MakeBytes([$AA, $BB, $CC])));
  TAssert.AssertEquals(23, Length(B));
  // magic 'NPF1'
  TAssert.AssertEquals(Ord('N'), B[0]);
  TAssert.AssertEquals(Ord('P'), B[1]);
  TAssert.AssertEquals(Ord('F'), B[2]);
  TAssert.AssertEquals(Ord('1'), B[3]);
  // kind=request, flags/reserved zerados
  TAssert.AssertEquals(1, B[4]);
  TAssert.AssertEquals(0, B[5]);
  TAssert.AssertEquals(0, B[6]);
  TAssert.AssertEquals(0, B[7]);
  // corrId little-endian
  TAssert.AssertEquals($88, B[8]);
  TAssert.AssertEquals($77, B[9]);
  TAssert.AssertEquals($66, B[10]);
  TAssert.AssertEquals($55, B[11]);
  TAssert.AssertEquals($44, B[12]);
  TAssert.AssertEquals($33, B[13]);
  TAssert.AssertEquals($22, B[14]);
  TAssert.AssertEquals($11, B[15]);
  // length little-endian
  TAssert.AssertEquals(3, B[16]);
  TAssert.AssertEquals(0, B[17]);
  TAssert.AssertEquals(0, B[18]);
  TAssert.AssertEquals(0, B[19]);
  // payload
  TAssert.AssertEquals($AA, B[20]);
  TAssert.AssertEquals($BB, B[21]);
  TAssert.AssertEquals($CC, B[22]);
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
  TAssert.AssertTrue('kind devia ser pfkMessage', LFrame.Kind = pfkMessage);
  TAssert.AssertTrue('corrId de msg devia ser 0', LFrame.CorrId = 0);
  TAssert.AssertEquals(5, Length(LFrame.Payload));
  for I := 0 to 4 do
    TAssert.AssertEquals(I + 1, LFrame.Payload[I]);
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
  TAssert.AssertTrue('primeiro frame devia ser request', LFrame.Kind = pfkRequest);
  TAssert.AssertTrue('corrId do request nao preservado', LFrame.CorrId = 42);
  TAssert.AssertEquals('ping', LFrame.PayloadAsText);

  LFrame := PipeReadFrame(FStream, 1024);
  TAssert.AssertTrue('segundo frame devia ser reply', LFrame.Kind = pfkReply);
  TAssert.AssertTrue('corrId do reply nao preservado', LFrame.CorrId = 42);
  TAssert.AssertEquals('pong', LFrame.PayloadAsText);
end;

procedure TPipeFramingTests.RoundTrip_PayloadVazio;
var
  LFrame: TPipeFrame;
begin
  FStream := TBytesStream.Create;
  PipeWriteFrame(FStream, TPipeFrame.Msg(nil), 1024);
  FStream.Position := 0;
  LFrame := PipeReadFrame(FStream, 1024);
  TAssert.AssertTrue(LFrame.Kind = pfkMessage);
  TAssert.AssertEquals(0, Length(LFrame.Payload));
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
  TAssert.AssertTrue(LFrame.Kind = pfkMessage);
  TAssert.AssertEquals(1, Length(LFrame.Payload));

  LFrame := PipeReadFrame(FStream, 1024);
  TAssert.AssertTrue(LFrame.Kind = pfkRequest);
  TAssert.AssertEquals(2, Length(LFrame.Payload));
  TAssert.AssertEquals(20, LFrame.Payload[0]);
  TAssert.AssertEquals(21, LFrame.Payload[1]);

  LFrame := PipeReadFrame(FStream, 1024);
  TAssert.AssertTrue(LFrame.Kind = pfkReply);
  TAssert.AssertTrue(LFrame.CorrId = 7);
  TAssert.AssertEquals(0, Length(LFrame.Payload));
end;

procedure TPipeFramingTests.RoundTrip_ErrorReply_PreservaFlagEMensagem;
var
  LFrame: TPipeFrame;
begin
  FStream := TBytesStream.Create;
  PipeWriteFrame(FStream, TPipeFrame.ErrorReply(7, 'falha proposital'), 1024);
  FStream.Position := 0;
  LFrame := PipeReadFrame(FStream, 1024);
  TAssert.AssertTrue('kind devia ser reply', LFrame.Kind = pfkReply);
  TAssert.AssertTrue('flag de erro nao preservada', LFrame.IsError);
  TAssert.AssertTrue('corrId nao preservado', LFrame.CorrId = 7);
  TAssert.AssertEquals('falha proposital', LFrame.PayloadAsText);
end;

procedure TPipeFramingTests.RoundTrip_Ping;
var
  LFrame: TPipeFrame;
begin
  // Heartbeat de aplicacao (Pipes.Base.HeartbeatIntervalMs): simetrico e sem
  // correlacao, entao o frame e' so' kind+CorrId=0+payload vazio.
  FStream := TBytesStream.Create;
  PipeWriteFrame(FStream, TPipeFrame.Ping, 1024);
  FStream.Position := 0;
  LFrame := PipeReadFrame(FStream, 1024);
  TAssert.AssertTrue('kind devia ser pfkPing', LFrame.Kind = pfkPing);
  TAssert.AssertTrue('corrId de ping devia ser 0', LFrame.CorrId = 0);
  TAssert.AssertEquals(0, Integer(LFrame.Flags));
  TAssert.AssertEquals(0, Length(LFrame.Payload));
end;

procedure TPipeFramingTests.ReadFrame_MagicInvalido_Levanta;
begin
  FStream := BuildStream([Ord('X'), Ord('P'), Ord('F'), Ord('1'),
    0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0]);
  TAssert.AssertException(EPipeProtocol, DoReadFromStream);
end;

procedure TPipeFramingTests.ReadFrame_KindDesconhecido_Levanta;
begin
  FStream := BuildStream([Ord('N'), Ord('P'), Ord('F'), Ord('1'),
    99, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0]);
  TAssert.AssertException(EPipeProtocol, DoReadFromStream);
end;

procedure TPipeFramingTests.ReadFrame_PayloadAcimaDoMaximo_Levanta;
begin
  // length = 101, maximo do teste = 100
  FStream := BuildStream([Ord('N'), Ord('P'), Ord('F'), Ord('1'),
    0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  101, 0, 0, 0]);
  TAssert.AssertException(EPipeProtocol, DoReadFromStream);
end;

procedure TPipeFramingTests.ReadFrame_StreamTruncado_Levanta;
begin
  // header anuncia 10 bytes de payload; so ha 3
  FStream := BuildStream([Ord('N'), Ord('P'), Ord('F'), Ord('1'),
    0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  10, 0, 0, 0,
    1, 2, 3]);
  TAssert.AssertException(EPipeClosed, DoReadFromStream);
end;

procedure TPipeFramingTests.WriteFrame_PayloadAcimaDoMaximo_Levanta;
var
  LBig: TBytes;
begin
  SetLength(LBig, 101); // maximo do teste = 100
  FFrame := TPipeFrame.Msg(LBig);
  FStream := TBytesStream.Create;
  TAssert.AssertException(EPipeProtocol, DoWriteToStream);
  TAssert.AssertEquals('falhou mas escreveu bytes no stream', Int64(0), FStream.Size);
end;

procedure TPipeFramingTests.WriteFrames_Vazio_NaoEscreveNada;
begin
  FFrames := nil;
  FStream := TBytesStream.Create;
  PipeWriteFrames(FStream, FFrames, 1024);
  TAssert.AssertEquals(Int64(0), FStream.Size);
end;

procedure TPipeFramingTests.WriteFrames_IdenticoASequenciaDeWriteFrame;
var
  LViaFrames, LViaLoop: TBytesStream;
  I: Integer;
begin
  // A garantia central de PipeWriteFrames e' amortizar a syscall sem mudar
  // UM byte do que vai no fio: o resultado tem que ser byte a byte igual a
  // escrever cada frame em sequencia com PipeWriteFrame.
  SetLength(FFrames, 3);
  FFrames[0] := TPipeFrame.Msg(MakeBytes([10]));
  FFrames[1] := TPipeFrame.Request(7, MakeBytes([20, 21]));
  FFrames[2] := TPipeFrame.Reply(7, nil);

  LViaFrames := TBytesStream.Create;
  LViaLoop := TBytesStream.Create;
  try
    PipeWriteFrames(LViaFrames, FFrames, 1024);
    for I := 0 to High(FFrames) do
      PipeWriteFrame(LViaLoop, FFrames[I], 1024);
    TAssert.AssertEquals(LViaLoop.Size, LViaFrames.Size);
    TAssert.AssertTrue('bytes divergem entre PipeWriteFrames e a sequencia de PipeWriteFrame',
      CompareMem(LViaFrames.Memory, LViaLoop.Memory, LViaLoop.Size));
  finally
    LViaFrames.Free;
    LViaLoop.Free;
  end;
end;

procedure TPipeFramingTests.WriteFrames_RoundTrip_PreservaOrdemEConteudo;
var
  LFrame: TPipeFrame;
begin
  SetLength(FFrames, 3);
  FFrames[0] := TPipeFrame.Msg(MakeBytes([10]));
  FFrames[1] := TPipeFrame.Request(7, MakeBytes([20, 21]));
  FFrames[2] := TPipeFrame.Reply(7, nil);

  FStream := TBytesStream.Create;
  PipeWriteFrames(FStream, FFrames, 1024);
  FStream.Position := 0;

  LFrame := PipeReadFrame(FStream, 1024);
  TAssert.AssertTrue(LFrame.Kind = pfkMessage);
  TAssert.AssertEquals(1, Length(LFrame.Payload));

  LFrame := PipeReadFrame(FStream, 1024);
  TAssert.AssertTrue(LFrame.Kind = pfkRequest);
  TAssert.AssertEquals(2, Length(LFrame.Payload));
  TAssert.AssertEquals(20, LFrame.Payload[0]);
  TAssert.AssertEquals(21, LFrame.Payload[1]);

  LFrame := PipeReadFrame(FStream, 1024);
  TAssert.AssertTrue(LFrame.Kind = pfkReply);
  TAssert.AssertTrue(LFrame.CorrId = 7);
  TAssert.AssertEquals(0, Length(LFrame.Payload));
end;

procedure TPipeFramingTests.WriteFrames_PayloadAcimaDoMaximo_LevantaSemEscreverNada;
var
  LBig: TBytes;
begin
  // O primeiro item e' valido; so' o segundo estoura o teto (100). A validacao
  // roda para TODOS antes de escrever qualquer byte, entao nem o primeiro
  // (valido) chega ao stream.
  SetLength(LBig, 101);
  SetLength(FFrames, 2);
  FFrames[0] := TPipeFrame.Msg(MakeBytes([1, 2, 3]));
  FFrames[1] := TPipeFrame.Msg(LBig);
  FStream := TBytesStream.Create;
  TAssert.AssertException(EPipeProtocol, DoWriteFramesToStream);
  TAssert.AssertEquals('falhou mas escreveu bytes no stream', Int64(0), FStream.Size);
end;

procedure TPipeFramingTests.Utf8_RoundTripAscii;
const
  S = 'named pipes 123';
begin
  TAssert.AssertEquals(S, PipeUtf8Decode(PipeUtf8Encode(S)));
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
  TAssert.AssertEquals(Length(LIn), Length(LOut));
  for I := 0 to High(LIn) do
    TAssert.AssertEquals(LIn[I], LOut[I]);
end;

initialization
  TDUnitX.RegisterTestFixture(TPipeFramingTests);

end.
