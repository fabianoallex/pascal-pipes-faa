unit Pipes.JsonTests;

{$mode delphi}{$H+}

{ GENERATED FILE — produced by tools/gen_fpc_mirror.py from
  tests/Integration/Pipes.JsonTests.pas (DUnitX). Do not edit by hand: edit the DUnitX
  master and run the script again. }

{ Testes do helper opcional Pipes.Json: fronteira bytes<->JSON (roundtrip,
  JSON invalido/vazio, UTF-8) e a fiacao de PipeSendJSON/PipeRequestJSON
  sobre um par servidor/cliente REAL (ptLocal). Mestre DUnitX; o espelho
  FPCUnit em tests/Integration/fpc e' gerado por tools/gen_fpc_mirror.py.

  Fica em Integration, nao em Unit: Pipes.Json.pas depende de Pipes.Client/
  Pipes.Server (para PipeSendJSON/PipeRequestJSON), entao a unit inteira nao
  e' "pura" na taxonomia deste projeto (ver cabecalho de
  tests/Unit/Pipes.TopicsTests.pas) mesmo com PipeBytesToJSON/PipeJSONToBytes
  isoladamente nao precisando de conexao nenhuma. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  SyncObjs,
  {$IFDEF FPC}fpjson,{$ELSE}System.JSON,{$ENDIF}
  Pipes.Types,
  PascalCommon.Threading,
  Pipes.Framing,
  Pipes.Server,
  Pipes.Client,
  Pipes.Json;

type
  TPipeJsonTests = class(TTestCase)
  private
    FServer: TPipeServer;
    FClient: TPipeClient;
    FLock: TCriticalSection;
    FReceived: TBytes;          // sob FLock
    FSrvMsgCount: Integer;      // atomico
    FPayload: TBytes;
    procedure DoParse; // PipeBytesToJSON(FPayload)
    procedure OnSrvMessage(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure OnSrvRequestDobraNumero(Sender: TObject; AConnId: TPipeConnectionId;
      const ARequest: TBytes; out AReply: TBytes);
    procedure OpenPair;
    function WaitCount(var ACounter: Integer; AExpected: Integer;
      ATimeoutMs: Cardinal): Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    // --- fronteira bytes<->JSON (nao abre conexao) ---
    procedure RoundTrip_ObjetoSimples;
    procedure RoundTrip_Utf8PreservaAcentos;
    procedure BytesToJSON_Invalido_Levanta;
    procedure BytesToJSON_Vazio_Levanta;
    procedure JSONToBytes_NaoLiberaAValue;
    // --- fiacao com servidor/cliente reais ---
    procedure SendJSON_ClienteParaServidor_ChegaComoJSON;
    procedure RequestJSON_EcoaComReplyTransformado;
  end;

implementation

var
  GNameSeq: Integer;

function UniquePipeName: string;
begin
  Result := 'pipes_faa_json_' + IntToStr(Int64(PcTickMs)) + '_' +
    IntToStr(PcAtomicInc(GNameSeq));
end;

// System.JSON (Delphi) e fpjson (FPC) nao tem a mesma API de objeto: estes
// helpers deixam o corpo dos testes igual nos dois compiladores.
procedure JsonAddStr(AObj: TJSONObject; const AName, AValue: string);
begin
  {$IFDEF FPC}
  AObj.Add(AName, AValue);
  {$ELSE}
  AObj.AddPair(AName, AValue);
  {$ENDIF}
end;

procedure JsonAddInt(AObj: TJSONObject; const AName: string; AValue: Integer);
begin
  {$IFDEF FPC}
  AObj.Add(AName, AValue);
  {$ELSE}
  AObj.AddPair(AName, TJSONNumber.Create(AValue));
  {$ENDIF}
end;

function JsonStr(AObj: TJSONObject; const AName: string): string;
begin
  {$IFDEF FPC}
  Result := AObj.Get(AName, '');
  {$ELSE}
  Result := AObj.GetValue<string>(AName);
  {$ENDIF}
end;

function JsonInt(AObj: TJSONObject; const AName: string): Integer;
begin
  {$IFDEF FPC}
  Result := AObj.Get(AName, 0);
  {$ELSE}
  Result := AObj.GetValue<Integer>(AName);
  {$ENDIF}
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

{ TPipeJsonTests }

procedure TPipeJsonTests.SetUp;
begin
  FLock := TCriticalSection.Create;
  FSrvMsgCount := 0;
end;

procedure TPipeJsonTests.TearDown;
begin
  FreeAndNil(FClient); // Disconnect no destructor
  FreeAndNil(FServer); // Stop no destructor
  FreeAndNil(FLock);
end;

function TPipeJsonTests.WaitCount(var ACounter: Integer; AExpected: Integer;
  ATimeoutMs: Cardinal): Boolean;
var
  LDeadline: UInt64;
begin
  LDeadline := PcTickMs + ATimeoutMs;
  while (PcAtomicGet(ACounter) < AExpected) and (PcTickMs < LDeadline) do
    Sleep(5);
  Result := PcAtomicGet(ACounter) >= AExpected;
end;

procedure TPipeJsonTests.OnSrvMessage(Sender: TObject;
  AConnId: TPipeConnectionId; const AData: TBytes);
begin
  FLock.Enter;
  try
    FReceived := AData;
  finally
    FLock.Leave;
  end;
  PcAtomicInc(FSrvMsgCount);
end;

procedure TPipeJsonTests.OnSrvRequestDobraNumero(Sender: TObject;
  AConnId: TPipeConnectionId; const ARequest: TBytes; out AReply: TBytes);
var
  LReq, LReply: TJSONObject;
begin
  LReq := PipeBytesToJSON(ARequest) as TJSONObject;
  try
    LReply := TJSONObject.Create;
    try
      JsonAddInt(LReply, 'numero', 2 * JsonInt(LReq, 'numero'));
      AReply := PipeJSONToBytes(LReply);
    finally
      LReply.Free;
    end;
  finally
    LReq.Free;
  end;
end;

procedure TPipeJsonTests.OpenPair;
var
  LName: string;
begin
  LName := UniquePipeName;
  FServer := TPipeServer.Create(LName);
  FServer.OnMessage := OnSrvMessage;
  FServer.OnRequest := OnSrvRequestDobraNumero;
  FServer.Listen;

  FClient := TPipeClient.Create(LName);
  FClient.Connect(3000);
end;

{ --- fronteira bytes<->JSON --- }

procedure TPipeJsonTests.DoParse;
var
  LValue: TPipeJSONValue;
begin
  LValue := PipeBytesToJSON(FPayload);
  LValue.Free; // so chega aqui se nao levantar
end;

procedure TPipeJsonTests.RoundTrip_ObjetoSimples;
var
  LObj, LParsed: TJSONObject;
  LBytes: TBytes;
begin
  LObj := TJSONObject.Create;
  try
    JsonAddStr(LObj, 'nome', 'caixa-3');
    JsonAddInt(LObj, 'numero', 42);
    LBytes := PipeJSONToBytes(LObj);
  finally
    LObj.Free;
  end;

  LParsed := PipeBytesToJSON(LBytes) as TJSONObject;
  try
    TAssert.AssertEquals('caixa-3', JsonStr(LParsed, 'nome'));
    TAssert.AssertEquals(42, JsonInt(LParsed, 'numero'));
  finally
    LParsed.Free;
  end;
end;

procedure TPipeJsonTests.RoundTrip_Utf8PreservaAcentos;
var
  LObj, LParsed: TJSONObject;
  LBytes: TBytes;
  LDescricao: string;
begin
  // 'secao' com cedilha e til, construido por BYTES UTF-8 - mesma razao de
  // Pipes.TopicsTests.Envelope_TopicoNaoAscii: nao depender do encoding
  // deste arquivo-fonte nem do codepage do compilador/console.
  LDescricao := PipeUtf8Decode(
    MakeBytes([Ord('s'), Ord('e'), $C3, $A7, $C3, $A3, Ord('o')]));

  LObj := TJSONObject.Create;
  try
    JsonAddStr(LObj, 'descricao', LDescricao);
    LBytes := PipeJSONToBytes(LObj);
  finally
    LObj.Free;
  end;

  LParsed := PipeBytesToJSON(LBytes) as TJSONObject;
  try
    TAssert.AssertEquals(LDescricao, JsonStr(LParsed, 'descricao'));
  finally
    LParsed.Free;
  end;
end;

procedure TPipeJsonTests.BytesToJSON_Invalido_Levanta;
begin
  FPayload := PipeUtf8Encode('{"nome": ');
  TAssert.AssertException(EPipeJSONError, DoParse);
end;

procedure TPipeJsonTests.BytesToJSON_Vazio_Levanta;
begin
  FPayload := nil;
  TAssert.AssertException(EPipeJSONError, DoParse);
end;

procedure TPipeJsonTests.JSONToBytes_NaoLiberaAValue;
var
  LObj: TJSONObject;
begin
  // Contrato: PipeJSONToBytes nao e' dono de AValue. Se liberasse, o
  // segundo acesso abaixo daria access violation / use-after-free.
  LObj := TJSONObject.Create;
  try
    JsonAddStr(LObj, 'x', '1');
    PipeJSONToBytes(LObj);
    TAssert.AssertEquals('1', JsonStr(LObj, 'x'));
  finally
    LObj.Free;
  end;
end;

{ --- fiacao com servidor/cliente reais --- }

procedure TPipeJsonTests.SendJSON_ClienteParaServidor_ChegaComoJSON;
var
  LObj, LParsed: TJSONObject;
  LSnapshot: TBytes;
begin
  OpenPair;
  LObj := TJSONObject.Create;
  try
    JsonAddStr(LObj, 'evento', 'abriu-caixa');
    JsonAddInt(LObj, 'caixa', 3);
    PipeSendJSON(FClient, LObj);
  finally
    LObj.Free;
  end;

  TAssert.AssertTrue('mensagem nao chegou ao servidor', WaitCount(FSrvMsgCount, 1, 3000));
  FLock.Enter;
  try
    LSnapshot := FReceived;
  finally
    FLock.Leave;
  end;

  LParsed := PipeBytesToJSON(LSnapshot) as TJSONObject;
  try
    TAssert.AssertEquals('abriu-caixa', JsonStr(LParsed, 'evento'));
    TAssert.AssertEquals(3, JsonInt(LParsed, 'caixa'));
  finally
    LParsed.Free;
  end;
end;

procedure TPipeJsonTests.RequestJSON_EcoaComReplyTransformado;
var
  LReq, LReply: TJSONObject;
begin
  OpenPair;
  LReq := TJSONObject.Create;
  try
    JsonAddInt(LReq, 'numero', 21);
    LReply := PipeRequestJSON(FClient, LReq, 3000) as TJSONObject;
    try
      TAssert.AssertEquals(42, JsonInt(LReply, 'numero'));
    finally
      LReply.Free;
    end;
  finally
    LReq.Free;
  end;
end;

initialization
  RegisterTest(TPipeJsonTests);

end.
