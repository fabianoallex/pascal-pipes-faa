unit Pipes.Framing;

{$I pipes.inc}

{ Wire format NPF1: framing por length-prefix, identico nos dois OS.

  O transporte (Named Pipe em modo byte no Windows, Unix Domain Socket no
  Linux) e' um fluxo de bytes sem fronteiras; as fronteiras de mensagem sao
  responsabilidade DESTA unit. Nao dependemos de PIPE_READMODE_MESSAGE.

  Frame (header de 20 bytes, little-endian, + payload):
    offset 0  Magic    4 bytes  'NPF1' (sincronia + versao do protocolo)
    offset 4  Kind     1 byte   0=msg  1=request  2=reply  3=ping (reservado)
    offset 5  Flags    1 byte   bit 0 (PIPE_FLAG_ERROR): reply de erro — o
                                payload e' a mensagem de erro em UTF-8
    offset 6  Reserved 2 bytes  (0)
    offset 8  CorrId   8 bytes  correlation id (request/reply; 0 em msg)
    offset 16 Length   4 bytes  tamanho do payload
    offset 20 Payload  Length bytes (TBytes cru; texto = UTF-8)

  Concorrencia: as funcoes desta unit nao tem estado compartilhado. Quem
  serializa escritas concorrentes no MESMO stream e' a camada de cima (write
  lock por conexao); PipeWriteFrame emite header+payload numa unica chamada
  Write para nao entrelacar frames entre transportes que respeitam a escrita
  como unidade. }

interface

uses
  SysUtils,
  Classes,
  Pipes.Types;

const
  PIPE_FRAME_HEADER_SIZE = 20;
  /// Flags bit 0: reply de erro (payload = mensagem de erro em UTF-8).
  PIPE_FLAG_ERROR = $01;

type
  TPipeFrameKind = (pfkMessage = 0, pfkRequest = 1, pfkReply = 2, pfkPing = 3);

  TPipeFrame = record
    Kind: TPipeFrameKind;
    Flags: Byte;
    CorrId: UInt64;
    Payload: TBytes;
    /// Payload interpretado como texto UTF-8.
    function PayloadAsText: string;
    function IsError: Boolean;
    class function Msg(const APayload: TBytes): TPipeFrame; static;
    class function Request(ACorrId: UInt64; const APayload: TBytes): TPipeFrame; static;
    class function Reply(ACorrId: UInt64; const APayload: TBytes): TPipeFrame; static;
    /// Reply de erro (request-reply): PIPE_FLAG_ERROR + mensagem no payload.
    class function ErrorReply(ACorrId: UInt64; const AMsgText: string): TPipeFrame; static;
  end;

// --- Conversao string <-> UTF-8 ---------------------------------------------
// No Delphi, string e' UTF-16 e a conversao e' TEncoding.UTF8. No FPC, string
// (AnsiString) carrega um codepage dinamico; convertemos via RawByteString +
// SetCodePage, que respeita o codepage real da string dos dois lados. Em apps
// Lazarus (DefaultSystemCodePage = UTF-8) o caminho todo e' lossless; em
// console FPC puro, configure SetMultiByteConversionCodePage(CP_UTF8) se for
// usar strings nao-ASCII. (Mesma abordagem do pascal-amqp-faa.)

function PipeUtf8Encode(const AValue: string): TBytes;
function PipeUtf8Decode(const ABytes: TBytes): string;

/// Serializa o frame (header + payload) num TBytes unico.
function PipeEncodeFrame(const AFrame: TPipeFrame): TBytes;

/// Le um frame completo do stream (bloqueia ate completar). EPipeClosed se o
/// stream acabar no meio (ou exatamente na fronteira entre frames: quem
/// distingue encerramento limpo de truncamento e' a camada de cima, pelo
/// estado da conexao). EPipeProtocol para magic invalido, kind desconhecido
/// ou payload acima de AMaxPayload.
function PipeReadFrame(AStream: TStream; AMaxPayload: Cardinal): TPipeFrame;

/// Escreve o frame no stream, header+payload numa unica chamada Write.
/// EPipeProtocol se o payload exceder AMaxPayload (falha antes de escrever).
procedure PipeWriteFrame(AStream: TStream; const AFrame: TPipeFrame;
  AMaxPayload: Cardinal);

implementation

const
  MAGIC0 = Ord('N');
  MAGIC1 = Ord('P');
  MAGIC2 = Ord('F');
  MAGIC3 = Ord('1');

{ --- string <-> UTF-8 --- }

{$IFDEF FPC}
function PipeUtf8Encode(const AValue: string): TBytes;
var
  R: RawByteString;
begin
  R := AValue;
  if (R <> '') and (StringCodePage(R) <> CP_UTF8) then
    SetCodePage(R, CP_UTF8, True); // converte do codepage real para UTF-8
  Result := nil;
  SetLength(Result, Length(R));
  if R <> '' then
    Move(R[1], Result[0], Length(R));
end;

function PipeUtf8Decode(const ABytes: TBytes): string;
var
  R: RawByteString;
begin
  SetLength(R, Length(ABytes));
  if Length(ABytes) > 0 then
    Move(ABytes[0], R[1], Length(ABytes));
  SetCodePage(R, CP_UTF8, False); // marca os bytes como UTF-8 (sem converter)
  Result := R; // conversao (se houver) respeita o codepage de destino
end;
{$ELSE}
function PipeUtf8Encode(const AValue: string): TBytes;
begin
  Result := TEncoding.UTF8.GetBytes(AValue);
end;

function PipeUtf8Decode(const ABytes: TBytes): string;
begin
  Result := TEncoding.UTF8.GetString(ABytes);
end;
{$ENDIF}

{ --- little-endian --- }

procedure PutU32LE(var ABuf: TBytes; AOffset: Integer; AValue: Cardinal);
begin
  ABuf[AOffset]     := Byte(AValue);
  ABuf[AOffset + 1] := Byte(AValue shr 8);
  ABuf[AOffset + 2] := Byte(AValue shr 16);
  ABuf[AOffset + 3] := Byte(AValue shr 24);
end;

procedure PutU64LE(var ABuf: TBytes; AOffset: Integer; AValue: UInt64);
var
  I: Integer;
begin
  for I := 0 to 7 do
    ABuf[AOffset + I] := Byte(AValue shr (8 * I));
end;

function GetU32LE(const ABuf: array of Byte; AOffset: Integer): Cardinal;
begin
  Result := Cardinal(ABuf[AOffset])
    or (Cardinal(ABuf[AOffset + 1]) shl 8)
    or (Cardinal(ABuf[AOffset + 2]) shl 16)
    or (Cardinal(ABuf[AOffset + 3]) shl 24);
end;

function GetU64LE(const ABuf: array of Byte; AOffset: Integer): UInt64;
var
  I: Integer;
begin
  Result := 0;
  for I := 7 downto 0 do
    Result := (Result shl 8) or ABuf[AOffset + I];
end;

{ TPipeFrame }

function TPipeFrame.PayloadAsText: string;
begin
  Result := PipeUtf8Decode(Payload);
end;

function TPipeFrame.IsError: Boolean;
begin
  Result := (Flags and PIPE_FLAG_ERROR) <> 0;
end;

class function TPipeFrame.Msg(const APayload: TBytes): TPipeFrame;
begin
  Result.Kind := pfkMessage;
  Result.Flags := 0;
  Result.CorrId := 0;
  Result.Payload := APayload;
end;

class function TPipeFrame.Request(ACorrId: UInt64; const APayload: TBytes): TPipeFrame;
begin
  Result.Kind := pfkRequest;
  Result.Flags := 0;
  Result.CorrId := ACorrId;
  Result.Payload := APayload;
end;

class function TPipeFrame.Reply(ACorrId: UInt64; const APayload: TBytes): TPipeFrame;
begin
  Result.Kind := pfkReply;
  Result.Flags := 0;
  Result.CorrId := ACorrId;
  Result.Payload := APayload;
end;

class function TPipeFrame.ErrorReply(ACorrId: UInt64; const AMsgText: string): TPipeFrame;
begin
  Result.Kind := pfkReply;
  Result.Flags := PIPE_FLAG_ERROR;
  Result.CorrId := ACorrId;
  Result.Payload := PipeUtf8Encode(AMsgText);
end;

{ --- encode / read / write --- }

function PipeEncodeFrame(const AFrame: TPipeFrame): TBytes;
var
  L: Integer;
begin
  L := Length(AFrame.Payload);
  Result := nil;
  SetLength(Result, PIPE_FRAME_HEADER_SIZE + L);
  Result[0] := MAGIC0;
  Result[1] := MAGIC1;
  Result[2] := MAGIC2;
  Result[3] := MAGIC3;
  Result[4] := Ord(AFrame.Kind);
  Result[5] := AFrame.Flags;
  Result[6] := 0; // Reserved
  Result[7] := 0;
  PutU64LE(Result, 8, AFrame.CorrId);
  PutU32LE(Result, 16, Cardinal(L));
  if L > 0 then
    Move(AFrame.Payload[0], Result[PIPE_FRAME_HEADER_SIZE], L);
end;

// Le exatamente ACount bytes (TStream.Read pode devolver parcial em sockets).
procedure ReadExactly(AStream: TStream; var ABuf; ACount: Integer);
var
  P: PByte;
  LRead: Integer;
begin
  P := @ABuf;
  while ACount > 0 do
  begin
    LRead := AStream.Read(P^, ACount);
    if LRead <= 0 then
      raise EPipeClosed.Create('stream encerrado durante a leitura de um frame');
    Inc(P, LRead);
    Dec(ACount, LRead);
  end;
end;

function PipeReadFrame(AStream: TStream; AMaxPayload: Cardinal): TPipeFrame;
var
  LHeader: array[0..PIPE_FRAME_HEADER_SIZE - 1] of Byte;
  LKind: Byte;
  LLen: Cardinal;
begin
  ReadExactly(AStream, LHeader, PIPE_FRAME_HEADER_SIZE);
  if (LHeader[0] <> MAGIC0) or (LHeader[1] <> MAGIC1) or
     (LHeader[2] <> MAGIC2) or (LHeader[3] <> MAGIC3) then
    raise EPipeProtocol.Create('magic invalido (stream fora de sincronia ou protocolo estranho)');
  LKind := LHeader[4];
  if LKind > Ord(High(TPipeFrameKind)) then
    raise EPipeProtocol.CreateFmt('kind de frame desconhecido (%d)', [LKind]);
  LLen := GetU32LE(LHeader, 16);
  if LLen > AMaxPayload then
    raise EPipeProtocol.CreateFmt('payload de %u bytes excede o maximo configurado (%u)',
      [LLen, AMaxPayload]);
  Result.Kind := TPipeFrameKind(LKind);
  Result.Flags := LHeader[5];
  Result.CorrId := GetU64LE(LHeader, 8);
  SetLength(Result.Payload, LLen);
  if LLen > 0 then
    ReadExactly(AStream, Result.Payload[0], Integer(LLen));
end;

procedure PipeWriteFrame(AStream: TStream; const AFrame: TPipeFrame;
  AMaxPayload: Cardinal);
var
  LBuf: TBytes;
begin
  if Cardinal(Length(AFrame.Payload)) > AMaxPayload then
    raise EPipeProtocol.CreateFmt('payload de %d bytes excede o maximo configurado (%u)',
      [Length(AFrame.Payload), AMaxPayload]);
  LBuf := PipeEncodeFrame(AFrame);
  AStream.WriteBuffer(LBuf[0], Length(LBuf));
end;

end.
