unit Pipes.JsonTests;

{ Testes do helper opcional Pipes.Json: fronteira bytes<->JSON (roundtrip,
  JSON invalido/vazio, UTF-8) e a fiacao de PipeSendJSON/PipeRequestJSON
  sobre um par servidor/cliente REAL (ptLocal). Versao DUnitX; espelha a
  versao FPCUnit em tests/Integration/fpc.

  Fica em Integration, nao em Unit: Pipes.Json.pas depende de Pipes.Client/
  Pipes.Server (para PipeSendJSON/PipeRequestJSON), entao a unit inteira nao
  e' "pura" na taxonomia deste projeto (ver cabecalho de
  tests/Unit/Pipes.TopicsTests.pas) mesmo com PipeBytesToJSON/PipeJSONToBytes
  isoladamente nao precisando de conexao nenhuma. }

interface

uses
  DUnitX.TestFramework,
  SysUtils,
  SyncObjs,
  System.JSON,
  Pipes.Types,
  Pipes.Threading,
  Pipes.Framing,
  Pipes.Server,
  Pipes.Client,
  Pipes.Json;

type
  [TestFixture]
  TPipeJsonTests = class
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
  public
    [Setup] procedure SetUp;
    [TearDown] procedure TearDown;
  published
    // --- fronteira bytes<->JSON (nao abre conexao) ---
    [Test] procedure RoundTrip_ObjetoSimples;
    [Test] procedure RoundTrip_Utf8PreservaAcentos;
    [Test] procedure BytesToJSON_Invalido_Levanta;
    [Test] procedure BytesToJSON_Vazio_Levanta;
    [Test] procedure JSONToBytes_NaoLiberaAValue;
    // --- fiacao com servidor/cliente reais ---
    [Test] procedure SendJSON_ClienteParaServidor_ChegaComoJSON;
    [Test] procedure RequestJSON_EcoaComReplyTransformado;
  end;

implementation

var
  GNameSeq: Integer;

function UniquePipeName: string;
begin
  Result := 'pipes_faa_json_' + IntToStr(Int64(PipeTickMs)) + '_' +
    IntToStr(PipeAtomicInc(GNameSeq));
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
  LDeadline := PipeTickMs + ATimeoutMs;
  while (PipeAtomicGet(ACounter) < AExpected) and (PipeTickMs < LDeadline) do
    Sleep(5);
  Result := PipeAtomicGet(ACounter) >= AExpected;
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
  PipeAtomicInc(FSrvMsgCount);
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
      LReply.AddPair('numero', TJSONNumber.Create(
        2 * LReq.GetValue<Integer>('numero')));
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
    LObj.AddPair('nome', 'caixa-3');
    LObj.AddPair('numero', TJSONNumber.Create(42));
    LBytes := PipeJSONToBytes(LObj);
  finally
    LObj.Free;
  end;

  LParsed := PipeBytesToJSON(LBytes) as TJSONObject;
  try
    Assert.AreEqual('caixa-3', LParsed.GetValue<string>('nome'));
    Assert.AreEqual(42, LParsed.GetValue<Integer>('numero'));
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
    LObj.AddPair('descricao', LDescricao);
    LBytes := PipeJSONToBytes(LObj);
  finally
    LObj.Free;
  end;

  LParsed := PipeBytesToJSON(LBytes) as TJSONObject;
  try
    Assert.AreEqual(LDescricao, LParsed.GetValue<string>('descricao'));
  finally
    LParsed.Free;
  end;
end;

procedure TPipeJsonTests.BytesToJSON_Invalido_Levanta;
begin
  FPayload := PipeUtf8Encode('{"nome": ');
  Assert.WillRaise(DoParse, EPipeJSONError);
end;

procedure TPipeJsonTests.BytesToJSON_Vazio_Levanta;
begin
  FPayload := nil;
  Assert.WillRaise(DoParse, EPipeJSONError);
end;

procedure TPipeJsonTests.JSONToBytes_NaoLiberaAValue;
var
  LObj: TJSONObject;
begin
  // Contrato: PipeJSONToBytes nao e' dono de AValue. Se liberasse, o
  // segundo acesso abaixo daria access violation / use-after-free.
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('x', '1');
    PipeJSONToBytes(LObj);
    Assert.AreEqual('1', LObj.GetValue<string>('x'));
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
    LObj.AddPair('evento', 'abriu-caixa');
    LObj.AddPair('caixa', TJSONNumber.Create(3));
    PipeSendJSON(FClient, LObj);
  finally
    LObj.Free;
  end;

  Assert.IsTrue(WaitCount(FSrvMsgCount, 1, 3000), 'mensagem nao chegou ao servidor');
  FLock.Enter;
  try
    LSnapshot := FReceived;
  finally
    FLock.Leave;
  end;

  LParsed := PipeBytesToJSON(LSnapshot) as TJSONObject;
  try
    Assert.AreEqual('abriu-caixa', LParsed.GetValue<string>('evento'));
    Assert.AreEqual(3, LParsed.GetValue<Integer>('caixa'));
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
    LReq.AddPair('numero', TJSONNumber.Create(21));
    LReply := PipeRequestJSON(FClient, LReq, 3000) as TJSONObject;
    try
      Assert.AreEqual(42, LReply.GetValue<Integer>('numero'));
    finally
      LReply.Free;
    end;
  finally
    LReq.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TPipeJsonTests);

end.
