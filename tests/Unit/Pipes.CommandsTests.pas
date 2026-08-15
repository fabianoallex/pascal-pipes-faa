unit Pipes.CommandsTests;

{ Testes do roteador de comandos por nome (Pipes.Commands): registro
  (duplicado, limites de tamanho, handler nil) e despacho via HandleMessage.
  Versao DUnitX/Delphi; a versao FPCUnit em tests/Unit/fpc espelha a mesma
  cobertura.

  Como em Pipes.TopicsTests, o alvo e' a unit inteira SEM abrir conexao:
  HandleMessage e' chamado direto, simulando o que Server.OnMessage faria. }

interface

uses
  DUnitX.TestFramework,
  SysUtils,
  Pipes.Types,
  Pipes.Framing,
  Pipes.Commands;

type
  [TestFixture]
  TPipeCommandsTests = class
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
    FLastReply: TBytes;

    procedure Reset;
    procedure OnPing(Sender: TObject; AConnId: TPipeConnectionId;
      const ACommand: string; const APayload: TBytes);
    procedure OnUnknown(Sender: TObject; AConnId: TPipeConnectionId;
      const ACommand: string; const APayload: TBytes);
    procedure OnInvalid(Sender: TObject; AConnId: TPipeConnectionId;
      const ACommand: string; const APayload: TBytes);
    procedure OnSomaRequest(Sender: TObject; AConnId: TPipeConnectionId;
      const ACommand: string; const APayload: TBytes; out AReply: TBytes);

    // --- alvos de Assert.WillRaise (procedure of object, nunca anonima) ---
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
    procedure DoRegisterRequestNomeVazio;
    procedure DoRegisterRequestDuplicado;
    procedure DoHandleRequestComandoDesconhecido;
    procedure DoHandleRequestPayloadAbaixoDoMinimo;
    procedure DoHandleRequestEnvelopeMalformado;
  published
    // --- registro ---
    [Test] procedure Registro_Simples_NaoLevanta;
    [Test] procedure Registro_NomeVazio_Levanta;
    [Test] procedure Registro_NomeMuitoLongo_Levanta;
    [Test] procedure Registro_HandlerNil_Levanta;
    [Test] procedure Registro_MinSizeInvalido_Levanta;
    [Test] procedure Registro_MaxSizeInvalido_Levanta;
    [Test] procedure Registro_MaxMenorQueMin_Levanta;
    [Test] procedure Registro_Duplicado_Levanta;
    // --- despacho ---
    [Test] procedure Despacho_ComandoRegistrado_ChamaHandlerSemPrefixo;
    [Test] procedure Despacho_ComandoDesconhecido_ChamaOnUnknownCommand;
    [Test] procedure Despacho_ComandoDesconhecido_SemAssinante_NaoLevanta;
    [Test] procedure Despacho_PayloadAbaixoDoMinimo_ChamaOnInvalidPayload;
    [Test] procedure Despacho_PayloadAcimaDoMaximo_ChamaOnInvalidPayload;
    [Test] procedure Despacho_PayloadNosLimites_ChamaHandler;
    [Test] procedure Despacho_SemLimite_QualquerTamanhoChamaHandler;
    [Test] procedure Despacho_EnvelopeMalformado_ChamaOnInvalidPayloadComComandoVazio;
    // --- envelope ---
    [Test] procedure Envelope_RoundTrip;
    [Test] procedure Envelope_LayoutBinario;
    [Test] procedure Envelope_CorpoVazio;
    [Test] procedure Envelope_ComandoNaoAscii;
    [Test] procedure Envelope_PayloadCurto_Levanta;
    [Test] procedure Envelope_CommandLenMaiorQuePayload_Levanta;
    [Test] procedure Envelope_NomeAcimaDoMaximo_Levanta;
    // --- registro (request) ---
    [Test] procedure RegistroRequest_Simples_NaoLevanta;
    [Test] procedure RegistroRequest_NomeVazio_Levanta;
    [Test] procedure RegistroRequest_Duplicado_Levanta;
    [Test] procedure RegistroRequest_MesmoNomeDoRegistroDeMensagem_NaoConflita;
    // --- despacho (request) ---
    [Test] procedure HandleRequest_ComandoRegistrado_ChamaHandlerEDevolveReply;
    [Test] procedure HandleRequest_ComandoDesconhecido_Levanta;
    [Test] procedure HandleRequest_PayloadAbaixoDoMinimo_Levanta;
    [Test] procedure HandleRequest_PayloadNosLimites_ChamaHandler;
    [Test] procedure HandleRequest_EnvelopeMalformado_Levanta;
  end;

implementation

// Length() e' NativeInt no Win64 e AreEqual<T> nao infere T com argumentos de
// tipos diferentes (E2532) — mesmo motivo do helper em Pipes.FramingTests.
procedure EqualInt(AExpected, AActual: Integer);
begin
  Assert.AreEqual(AExpected, AActual);
end;

procedure EqualByte(AExpected: Integer; AActual: Byte);
begin
  Assert.AreEqual(AExpected, Integer(AActual));
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
  FLastReply := nil;
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

procedure TPipeCommandsTests.OnSomaRequest(Sender: TObject; AConnId: TPipeConnectionId;
  const ACommand: string; const APayload: TBytes; out AReply: TBytes);
begin
  FHandlerCalled := True;
  FLastSender := Sender;
  FLastConnId := AConnId;
  FLastCommand := ACommand;
  FLastPayload := APayload;
  AReply := MakeBytes([Length(APayload)]); // reply simples so' pra provar que chegou
  FLastReply := AReply;
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

procedure TPipeCommandsTests.DoRegisterRequestNomeVazio;
begin
  FRouter.RegisterRequestCommand('', OnSomaRequest);
end;

procedure TPipeCommandsTests.DoRegisterRequestDuplicado;
begin
  FRouter.RegisterRequestCommand('SOMA', OnSomaRequest);
end;

procedure TPipeCommandsTests.DoHandleRequestComandoDesconhecido;
var
  LReply: TBytes;
begin
  FRouter.HandleRequest(Self, 1, PipeEncodeCommandPayload('DESCONHECIDO', nil), LReply);
end;

procedure TPipeCommandsTests.DoHandleRequestPayloadAbaixoDoMinimo;
var
  LReply: TBytes;
begin
  FRouter.HandleRequest(Self, 1,
    PipeEncodeCommandPayload('SOMA', MakeBytes([1, 2])), LReply);
end;

procedure TPipeCommandsTests.DoHandleRequestEnvelopeMalformado;
var
  LReply: TBytes;
begin
  FRouter.HandleRequest(Self, 1, MakeBytes([5]), LReply); // nem o u16 cabe
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
    Assert.WillRaise(DoRegisterNomeVazio, EPipeCommandError);
  finally
    FRouter.Free;
  end;
end;

procedure TPipeCommandsTests.Registro_NomeMuitoLongo_Levanta;
begin
  FRouter := TPipeCommandRouter.Create;
  try
    Assert.WillRaise(DoRegisterNomeMuitoLongo, EPipeCommandError);
  finally
    FRouter.Free;
  end;
end;

procedure TPipeCommandsTests.Registro_HandlerNil_Levanta;
begin
  FRouter := TPipeCommandRouter.Create;
  try
    Assert.WillRaise(DoRegisterHandlerNil, EPipeCommandError);
  finally
    FRouter.Free;
  end;
end;

procedure TPipeCommandsTests.Registro_MinSizeInvalido_Levanta;
begin
  FRouter := TPipeCommandRouter.Create;
  try
    Assert.WillRaise(DoRegisterMinSizeInvalido, EPipeCommandError);
  finally
    FRouter.Free;
  end;
end;

procedure TPipeCommandsTests.Registro_MaxSizeInvalido_Levanta;
begin
  FRouter := TPipeCommandRouter.Create;
  try
    Assert.WillRaise(DoRegisterMaxSizeInvalido, EPipeCommandError);
  finally
    FRouter.Free;
  end;
end;

procedure TPipeCommandsTests.Registro_MaxMenorQueMin_Levanta;
begin
  FRouter := TPipeCommandRouter.Create;
  try
    Assert.WillRaise(DoRegisterMaxMenorQueMin, EPipeCommandError);
  finally
    FRouter.Free;
  end;
end;

procedure TPipeCommandsTests.Registro_Duplicado_Levanta;
begin
  FRouter := TPipeCommandRouter.Create;
  try
    FRouter.RegisterCommand('PING', OnPing);
    Assert.WillRaise(DoRegisterDuplicado, EPipeCommandError);
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
    Assert.IsTrue(FHandlerCalled);
    Assert.AreSame(LSender, FLastSender);
    EqualInt(7, FLastConnId);
    Assert.AreEqual('PING', FLastCommand);
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
    Assert.IsTrue(FUnknownCalled);
    Assert.IsFalse(FHandlerCalled);
    Assert.AreEqual('SAVE_ORDER', FLastCommand);
  finally
    FRouter.Free;
  end;
end;

procedure TPipeCommandsTests.Despacho_ComandoDesconhecido_SemAssinante_NaoLevanta;
begin
  Reset;
  FRouter := TPipeCommandRouter.Create;
  try
    // Sem OnUnknownCommand atribuido: mesmo silencio de um OnMessage sem
    // assinante, nao pode levantar nem travar.
    FRouter.HandleMessage(Self, 1,
      PipeEncodeCommandPayload('SAVE_ORDER', nil));
    Assert.IsFalse(FHandlerCalled);
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
    Assert.IsTrue(FInvalidCalled);
    Assert.IsFalse(FHandlerCalled);
    Assert.AreEqual('PING', FLastCommand);
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
    Assert.IsTrue(FInvalidCalled);
    Assert.IsFalse(FHandlerCalled);
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
    Assert.IsTrue(FHandlerCalled);
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
    Assert.IsTrue(FHandlerCalled);
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
    Assert.IsTrue(FInvalidCalled);
    Assert.AreEqual('', FLastCommand);
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
  Assert.AreEqual('SAVE_ORDER', LCommand);
  EqualInt(4, Length(LBody));
  EqualByte(10, LBody[0]);
  EqualByte(40, LBody[3]);
end;

procedure TPipeCommandsTests.Envelope_LayoutBinario;
var
  LBuf: TBytes;
begin
  // Layout no fio: u16 LE com o tamanho do nome, nome UTF-8, corpo.
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
  Assert.AreEqual('PING', LCommand);
  EqualInt(0, Length(LBody));
end;

procedure TPipeCommandsTests.Envelope_ComandoNaoAscii;
var
  LCommand: string;
  LBody, LIn, LOut: TBytes;
  I: Integer;
begin
  // O tamanho no envelope e' em BYTES UTF-8, nao em caracteres (mesmo caso de
  // Pipes.TopicsTests.Envelope_TopicoNaoAscii).
  LIn := MakeBytes([Ord('s'), Ord('e'), $C3, $A7, $C3, $A3, Ord('o')]);
  FPayload := PipeEncodeCommandPayload(PipeUtf8Decode(LIn), MakeBytes([1]));
  EqualByte(7, FPayload[0]); // 7 bytes, nao 5 caracteres
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
  FPayload := MakeBytes([5]); // 1 byte: nem o u16 do tamanho cabe
  Assert.WillRaise(DoDecodeTruncado, EPipeProtocol);
end;

procedure TPipeCommandsTests.Envelope_CommandLenMaiorQuePayload_Levanta;
begin
  // Vem da rede: entrada hostil por definicao, o decode nao pode ler alem.
  FPayload := MakeBytes([200, 0, Ord('a')]);
  Assert.WillRaise(DoDecodeLenMaiorQuePayload, EPipeProtocol);
end;

procedure TPipeCommandsTests.Envelope_NomeAcimaDoMaximo_Levanta;
begin
  Assert.WillRaise(DoEncodeNomeAcimaDoMaximo, EPipeProtocol);
end;

{ --- registro (request) --- }

procedure TPipeCommandsTests.RegistroRequest_Simples_NaoLevanta;
begin
  FRouter := TPipeCommandRouter.Create;
  try
    FRouter.RegisterRequestCommand('SOMA', OnSomaRequest);
  finally
    FRouter.Free;
  end;
end;

procedure TPipeCommandsTests.RegistroRequest_NomeVazio_Levanta;
begin
  FRouter := TPipeCommandRouter.Create;
  try
    Assert.WillRaise(DoRegisterRequestNomeVazio, EPipeCommandError);
  finally
    FRouter.Free;
  end;
end;

procedure TPipeCommandsTests.RegistroRequest_Duplicado_Levanta;
begin
  FRouter := TPipeCommandRouter.Create;
  try
    FRouter.RegisterRequestCommand('SOMA', OnSomaRequest);
    Assert.WillRaise(DoRegisterRequestDuplicado, EPipeCommandError);
  finally
    FRouter.Free;
  end;
end;

procedure TPipeCommandsTests.RegistroRequest_MesmoNomeDoRegistroDeMensagem_NaoConflita;
begin
  // Os dois registros (mensagem/request) sao independentes: o mesmo nome
  // pode existir nos dois sem EPipeCommandError de duplicado.
  FRouter := TPipeCommandRouter.Create;
  try
    FRouter.RegisterCommand('PING', OnPing);
    FRouter.RegisterRequestCommand('PING', OnSomaRequest);
  finally
    FRouter.Free;
  end;
end;

{ --- despacho (request) --- }

procedure TPipeCommandsTests.HandleRequest_ComandoRegistrado_ChamaHandlerEDevolveReply;
var
  LSender: TObject;
  LReply: TBytes;
begin
  Reset;
  FRouter := TPipeCommandRouter.Create;
  LSender := TObject.Create;
  try
    FRouter.RegisterRequestCommand('SOMA', OnSomaRequest);
    FRouter.HandleRequest(LSender, 7,
      PipeEncodeCommandPayload('SOMA', MakeBytes([1, 2, 3])), LReply);
    Assert.IsTrue(FHandlerCalled);
    Assert.AreSame(LSender, FLastSender);
    EqualInt(7, FLastConnId);
    Assert.AreEqual('SOMA', FLastCommand);
    EqualInt(3, Length(FLastPayload));
    EqualInt(1, Length(LReply));
    EqualByte(3, LReply[0]);
  finally
    FRouter.Free;
    LSender.Free;
  end;
end;

procedure TPipeCommandsTests.HandleRequest_ComandoDesconhecido_Levanta;
begin
  Reset;
  FRouter := TPipeCommandRouter.Create;
  try
    Assert.WillRaise(DoHandleRequestComandoDesconhecido, EPipeProtocol);
    Assert.IsFalse(FHandlerCalled);
  finally
    FRouter.Free;
  end;
end;

procedure TPipeCommandsTests.HandleRequest_PayloadAbaixoDoMinimo_Levanta;
begin
  Reset;
  FRouter := TPipeCommandRouter.Create;
  try
    FRouter.RegisterRequestCommand('SOMA', OnSomaRequest, 3, PIPE_COMMAND_NO_LIMIT);
    Assert.WillRaise(DoHandleRequestPayloadAbaixoDoMinimo, EPipeProtocol);
    Assert.IsFalse(FHandlerCalled);
  finally
    FRouter.Free;
  end;
end;

procedure TPipeCommandsTests.HandleRequest_PayloadNosLimites_ChamaHandler;
var
  LReply: TBytes;
begin
  Reset;
  FRouter := TPipeCommandRouter.Create;
  try
    FRouter.RegisterRequestCommand('SOMA', OnSomaRequest, 2, 2);
    FRouter.HandleRequest(Self, 1,
      PipeEncodeCommandPayload('SOMA', MakeBytes([1, 2])), LReply);
    Assert.IsTrue(FHandlerCalled);
    EqualInt(2, Length(FLastPayload));
  finally
    FRouter.Free;
  end;
end;

procedure TPipeCommandsTests.HandleRequest_EnvelopeMalformado_Levanta;
begin
  Reset;
  FRouter := TPipeCommandRouter.Create;
  try
    Assert.WillRaise(DoHandleRequestEnvelopeMalformado, EPipeProtocol);
    Assert.IsFalse(FHandlerCalled);
  finally
    FRouter.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TPipeCommandsTests);

end.
