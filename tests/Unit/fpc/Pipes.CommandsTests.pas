unit Pipes.CommandsTests;

{$mode delphi}{$H+}

{ Testes do roteador de comandos por nome (Pipes.Commands). Versao FPCUnit;
  espelha a cobertura da versao DUnitX em tests/Unit. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  Pipes.Types,
  Pipes.Framing,
  Pipes.Commands;

type
  TPipeCommandsTests = class(TTestCase)
  private
    FRouter: TPipeCommandRouter;
    FPayload: TBytes;
    FHandlerCalled: Boolean;
    FUnknownCalled: Boolean;
    FInvalidCalled: Boolean;
    FLastSender: TObject;
    FLastConnId: TPipeConnectionId;
    FLastCommand: string;
    FLastPayload: TBytes;

    procedure Reset;
    procedure OnPing(Sender: TObject; AConnId: TPipeConnectionId;
      const ACommand: string; const APayload: TBytes);
    procedure OnUnknown(Sender: TObject; AConnId: TPipeConnectionId;
      const ACommand: string; const APayload: TBytes);
    procedure OnInvalid(Sender: TObject; AConnId: TPipeConnectionId;
      const ACommand: string; const APayload: TBytes);

    procedure DoRegisterNomeVazio;
    procedure DoRegisterNomeMuitoLongo;
    procedure DoRegisterHandlerNil;
    procedure DoRegisterMinSizeInvalido;
    procedure DoRegisterMaxSizeInvalido;
    procedure DoRegisterMaxMenorQueMin;
    procedure DoRegisterDuplicado;
    procedure DoDecodeTruncado;
    procedure DoDecodeLenMaiorQuePayload;
    procedure DoEncodeNomeAcimaDoMaximo;
  published
    // --- registro ---
    procedure Registro_Simples_NaoLevanta;
    procedure Registro_NomeVazio_Levanta;
    procedure Registro_NomeMuitoLongo_Levanta;
    procedure Registro_HandlerNil_Levanta;
    procedure Registro_MinSizeInvalido_Levanta;
    procedure Registro_MaxSizeInvalido_Levanta;
    procedure Registro_MaxMenorQueMin_Levanta;
    procedure Registro_Duplicado_Levanta;
    // --- despacho ---
    procedure Despacho_ComandoRegistrado_ChamaHandlerSemPrefixo;
    procedure Despacho_ComandoDesconhecido_ChamaOnUnknownCommand;
    procedure Despacho_ComandoDesconhecido_SemAssinante_NaoLevanta;
    procedure Despacho_PayloadAbaixoDoMinimo_ChamaOnInvalidPayload;
    procedure Despacho_PayloadAcimaDoMaximo_ChamaOnInvalidPayload;
    procedure Despacho_PayloadNosLimites_ChamaHandler;
    procedure Despacho_SemLimite_QualquerTamanhoChamaHandler;
    procedure Despacho_EnvelopeMalformado_ChamaOnInvalidPayloadComComandoVazio;
    // --- envelope ---
    procedure Envelope_RoundTrip;
    procedure Envelope_LayoutBinario;
    procedure Envelope_CorpoVazio;
    procedure Envelope_ComandoNaoAscii;
    procedure Envelope_PayloadCurto_Levanta;
    procedure Envelope_CommandLenMaiorQuePayload_Levanta;
    procedure Envelope_NomeAcimaDoMaximo_Levanta;
  end;

implementation

// Forca a sobrecarga nao-generica AssertEquals(Integer, Integer).
procedure EqualInt(AExpected, AActual: Integer);
begin
  TAssert.AssertEquals(AExpected, AActual);
end;

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

{ TPipeCommandsTests }

procedure TPipeCommandsTests.Reset;
begin
  FHandlerCalled := False;
  FUnknownCalled := False;
  FInvalidCalled := False;
  FLastSender := nil;
  FLastConnId := 0;
  FLastCommand := '';
  FLastPayload := nil;
end;

procedure TPipeCommandsTests.OnPing(Sender: TObject; AConnId: TPipeConnectionId;
  const ACommand: string; const APayload: TBytes);
begin
  FHandlerCalled := True;
  FLastSender := Sender;
  FLastConnId := AConnId;
  FLastCommand := ACommand;
  FLastPayload := APayload;
end;

procedure TPipeCommandsTests.OnUnknown(Sender: TObject; AConnId: TPipeConnectionId;
  const ACommand: string; const APayload: TBytes);
begin
  FUnknownCalled := True;
  FLastCommand := ACommand;
  FLastPayload := APayload;
end;

procedure TPipeCommandsTests.OnInvalid(Sender: TObject; AConnId: TPipeConnectionId;
  const ACommand: string; const APayload: TBytes);
begin
  FInvalidCalled := True;
  FLastCommand := ACommand;
  FLastPayload := APayload;
end;

procedure TPipeCommandsTests.DoRegisterNomeVazio;
begin
  FRouter.RegisterCommand('', OnPing);
end;

procedure TPipeCommandsTests.DoRegisterNomeMuitoLongo;
begin
  FRouter.RegisterCommand(StringOfChar('a', PIPE_MAX_COMMAND_BYTES + 1), OnPing);
end;

procedure TPipeCommandsTests.DoRegisterHandlerNil;
begin
  FRouter.RegisterCommand('PING', nil);
end;

procedure TPipeCommandsTests.DoRegisterMinSizeInvalido;
begin
  FRouter.RegisterCommand('PING', OnPing, -2, PIPE_COMMAND_NO_LIMIT);
end;

procedure TPipeCommandsTests.DoRegisterMaxSizeInvalido;
begin
  FRouter.RegisterCommand('PING', OnPing, PIPE_COMMAND_NO_LIMIT, -2);
end;

procedure TPipeCommandsTests.DoRegisterMaxMenorQueMin;
begin
  FRouter.RegisterCommand('PING', OnPing, 10, 5);
end;

procedure TPipeCommandsTests.DoRegisterDuplicado;
begin
  FRouter.RegisterCommand('PING', OnPing);
end;

procedure TPipeCommandsTests.DoDecodeTruncado;
var
  LCommand: string;
  LBody: TBytes;
begin
  PipeDecodeCommandPayload(FPayload, LCommand, LBody);
end;

procedure TPipeCommandsTests.DoDecodeLenMaiorQuePayload;
var
  LCommand: string;
  LBody: TBytes;
begin
  PipeDecodeCommandPayload(FPayload, LCommand, LBody);
end;

procedure TPipeCommandsTests.DoEncodeNomeAcimaDoMaximo;
begin
  PipeEncodeCommandPayload(StringOfChar('a', PIPE_MAX_COMMAND_BYTES + 1), nil);
end;

{ --- registro --- }

procedure TPipeCommandsTests.Registro_Simples_NaoLevanta;
begin
  FRouter := TPipeCommandRouter.Create;
  try
    FRouter.RegisterCommand('PING', OnPing);
  finally
    FRouter.Free;
  end;
end;

procedure TPipeCommandsTests.Registro_NomeVazio_Levanta;
begin
  FRouter := TPipeCommandRouter.Create;
  try
    AssertException(EPipeCommandError, DoRegisterNomeVazio);
  finally
    FRouter.Free;
  end;
end;

procedure TPipeCommandsTests.Registro_NomeMuitoLongo_Levanta;
begin
  FRouter := TPipeCommandRouter.Create;
  try
    AssertException(EPipeCommandError, DoRegisterNomeMuitoLongo);
  finally
    FRouter.Free;
  end;
end;

procedure TPipeCommandsTests.Registro_HandlerNil_Levanta;
begin
  FRouter := TPipeCommandRouter.Create;
  try
    AssertException(EPipeCommandError, DoRegisterHandlerNil);
  finally
    FRouter.Free;
  end;
end;

procedure TPipeCommandsTests.Registro_MinSizeInvalido_Levanta;
begin
  FRouter := TPipeCommandRouter.Create;
  try
    AssertException(EPipeCommandError, DoRegisterMinSizeInvalido);
  finally
    FRouter.Free;
  end;
end;

procedure TPipeCommandsTests.Registro_MaxSizeInvalido_Levanta;
begin
  FRouter := TPipeCommandRouter.Create;
  try
    AssertException(EPipeCommandError, DoRegisterMaxSizeInvalido);
  finally
    FRouter.Free;
  end;
end;

procedure TPipeCommandsTests.Registro_MaxMenorQueMin_Levanta;
begin
  FRouter := TPipeCommandRouter.Create;
  try
    AssertException(EPipeCommandError, DoRegisterMaxMenorQueMin);
  finally
    FRouter.Free;
  end;
end;

procedure TPipeCommandsTests.Registro_Duplicado_Levanta;
begin
  FRouter := TPipeCommandRouter.Create;
  try
    FRouter.RegisterCommand('PING', OnPing);
    AssertException(EPipeCommandError, DoRegisterDuplicado);
  finally
    FRouter.Free;
  end;
end;

{ --- despacho --- }

procedure TPipeCommandsTests.Despacho_ComandoRegistrado_ChamaHandlerSemPrefixo;
var
  LSender: TObject;
begin
  Reset;
  FRouter := TPipeCommandRouter.Create;
  LSender := TObject.Create;
  try
    FRouter.RegisterCommand('PING', OnPing);
    FRouter.HandleMessage(LSender, 7,
      PipeEncodeCommandPayload('PING', MakeBytes([1, 2, 3])));
    AssertTrue(FHandlerCalled);
    AssertTrue(LSender = FLastSender);
    EqualInt(7, FLastConnId);
    AssertEquals('PING', FLastCommand);
    EqualInt(3, Length(FLastPayload));
    EqualByte(1, FLastPayload[0]);
  finally
    FRouter.Free;
    LSender.Free;
  end;
end;

procedure TPipeCommandsTests.Despacho_ComandoDesconhecido_ChamaOnUnknownCommand;
begin
  Reset;
  FRouter := TPipeCommandRouter.Create;
  try
    FRouter.OnUnknownCommand := OnUnknown;
    FRouter.HandleMessage(Self, 1,
      PipeEncodeCommandPayload('SAVE_ORDER', MakeBytes([9])));
    AssertTrue(FUnknownCalled);
    AssertFalse(FHandlerCalled);
    AssertEquals('SAVE_ORDER', FLastCommand);
  finally
    FRouter.Free;
  end;
end;

procedure TPipeCommandsTests.Despacho_ComandoDesconhecido_SemAssinante_NaoLevanta;
begin
  Reset;
  FRouter := TPipeCommandRouter.Create;
  try
    FRouter.HandleMessage(Self, 1,
      PipeEncodeCommandPayload('SAVE_ORDER', nil));
    AssertFalse(FHandlerCalled);
  finally
    FRouter.Free;
  end;
end;

procedure TPipeCommandsTests.Despacho_PayloadAbaixoDoMinimo_ChamaOnInvalidPayload;
begin
  Reset;
  FRouter := TPipeCommandRouter.Create;
  try
    FRouter.RegisterCommand('PING', OnPing, 3, PIPE_COMMAND_NO_LIMIT);
    FRouter.OnInvalidPayload := OnInvalid;
    FRouter.HandleMessage(Self, 1,
      PipeEncodeCommandPayload('PING', MakeBytes([1, 2])));
    AssertTrue(FInvalidCalled);
    AssertFalse(FHandlerCalled);
    AssertEquals('PING', FLastCommand);
  finally
    FRouter.Free;
  end;
end;

procedure TPipeCommandsTests.Despacho_PayloadAcimaDoMaximo_ChamaOnInvalidPayload;
begin
  Reset;
  FRouter := TPipeCommandRouter.Create;
  try
    FRouter.RegisterCommand('PING', OnPing, PIPE_COMMAND_NO_LIMIT, 2);
    FRouter.OnInvalidPayload := OnInvalid;
    FRouter.HandleMessage(Self, 1,
      PipeEncodeCommandPayload('PING', MakeBytes([1, 2, 3])));
    AssertTrue(FInvalidCalled);
    AssertFalse(FHandlerCalled);
  finally
    FRouter.Free;
  end;
end;

procedure TPipeCommandsTests.Despacho_PayloadNosLimites_ChamaHandler;
begin
  Reset;
  FRouter := TPipeCommandRouter.Create;
  try
    FRouter.RegisterCommand('PING', OnPing, 2, 2);
    FRouter.HandleMessage(Self, 1,
      PipeEncodeCommandPayload('PING', MakeBytes([1, 2])));
    AssertTrue(FHandlerCalled);
    EqualInt(2, Length(FLastPayload));
  finally
    FRouter.Free;
  end;
end;

procedure TPipeCommandsTests.Despacho_SemLimite_QualquerTamanhoChamaHandler;
begin
  Reset;
  FRouter := TPipeCommandRouter.Create;
  try
    FRouter.RegisterCommand('PING', OnPing);
    FRouter.HandleMessage(Self, 1, PipeEncodeCommandPayload('PING', nil));
    AssertTrue(FHandlerCalled);
    EqualInt(0, Length(FLastPayload));
  finally
    FRouter.Free;
  end;
end;

procedure TPipeCommandsTests.Despacho_EnvelopeMalformado_ChamaOnInvalidPayloadComComandoVazio;
begin
  Reset;
  FRouter := TPipeCommandRouter.Create;
  try
    FRouter.OnInvalidPayload := OnInvalid;
    FRouter.HandleMessage(Self, 1, MakeBytes([5])); // nem o u16 cabe
    AssertTrue(FInvalidCalled);
    AssertEquals('', FLastCommand);
  finally
    FRouter.Free;
  end;
end;

{ --- envelope --- }

procedure TPipeCommandsTests.Envelope_RoundTrip;
var
  LCommand: string;
  LBody: TBytes;
begin
  FPayload := PipeEncodeCommandPayload('SAVE_ORDER', MakeBytes([10, 20, 30, 40]));
  PipeDecodeCommandPayload(FPayload, LCommand, LBody);
  AssertEquals('SAVE_ORDER', LCommand);
  EqualInt(4, Length(LBody));
  EqualByte(10, LBody[0]);
  EqualByte(40, LBody[3]);
end;

procedure TPipeCommandsTests.Envelope_LayoutBinario;
var
  LBuf: TBytes;
begin
  LBuf := PipeEncodeCommandPayload('ab', MakeBytes([99]));
  EqualInt(5, Length(LBuf));
  EqualByte(2, LBuf[0]);
  EqualByte(0, LBuf[1]);
  EqualByte(Ord('a'), LBuf[2]);
  EqualByte(Ord('b'), LBuf[3]);
  EqualByte(99, LBuf[4]);
end;

procedure TPipeCommandsTests.Envelope_CorpoVazio;
var
  LCommand: string;
  LBody: TBytes;
begin
  FPayload := PipeEncodeCommandPayload('PING', nil);
  PipeDecodeCommandPayload(FPayload, LCommand, LBody);
  AssertEquals('PING', LCommand);
  EqualInt(0, Length(LBody));
end;

procedure TPipeCommandsTests.Envelope_ComandoNaoAscii;
var
  LCommand: string;
  LBody, LIn, LOut: TBytes;
  I: Integer;
begin
  LIn := MakeBytes([Ord('s'), Ord('e'), $C3, $A7, $C3, $A3, Ord('o')]);
  FPayload := PipeEncodeCommandPayload(PipeUtf8Decode(LIn), MakeBytes([1]));
  EqualByte(7, FPayload[0]);
  EqualByte(0, FPayload[1]);
  PipeDecodeCommandPayload(FPayload, LCommand, LBody);
  LOut := PipeUtf8Encode(LCommand);
  EqualInt(Length(LIn), Length(LOut));
  for I := 0 to High(LIn) do
    EqualByte(LIn[I], LOut[I]);
  EqualInt(1, Length(LBody));
end;

procedure TPipeCommandsTests.Envelope_PayloadCurto_Levanta;
begin
  FPayload := MakeBytes([5]);
  AssertException(EPipeProtocol, DoDecodeTruncado);
end;

procedure TPipeCommandsTests.Envelope_CommandLenMaiorQuePayload_Levanta;
begin
  FPayload := MakeBytes([200, 0, Ord('a')]);
  AssertException(EPipeProtocol, DoDecodeLenMaiorQuePayload);
end;

procedure TPipeCommandsTests.Envelope_NomeAcimaDoMaximo_Levanta;
begin
  AssertException(EPipeProtocol, DoEncodeNomeAcimaDoMaximo);
end;

initialization
  RegisterTest(TPipeCommandsTests);

end.
