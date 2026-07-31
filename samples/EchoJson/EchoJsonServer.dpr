program EchoJsonServer;

{ Servidor de eco console com payload JSON, mesma ideia do EchoServer mas
  usando Pipes.Json.pas (helper OPCIONAL, ver README.md secao "JSON") em vez
  de texto cru: recebe um pedido (item, quantidade), confirma de volta de
  forma assincrona (PipeSendJSON, cai no OnMessage do cliente) e responde
  requests sincronos (PipeRequestJSON do cliente) com o total calculado.

  Pipes.Json.pas nao unifica a API de montar/ler o valor (AddPair vs Add,
  GetValue<T> vs Get) - so' a fronteira bytes<->JSON. MakePedido/JStr/JInt
  isolam essa diferenca atras de IFDEF FPC; o resto do sample nao sabe qual
  lib esta por baixo.

  JSON invalido chegando por OnMessage e' logado e descartado (o remetente
  nao tem quem avisar num fire-and-forget); chegando por OnRequest, deixa
  EPipeJSONError propagar - o framework transforma em reply de erro para o
  cliente, o mesmo mecanismo de qualquer excecao dentro de OnRequest.

  Compila nos dois mundos a partir do MESMO fonte:
    FPC:    fpc -MDelphi -Sh -Fu..\..\src EchoJsonServer.dpr  (ou lazbuild EchoJsonServer.lpi)
    Delphi: abrir EchoJsonServer.dproj no IDE

  Uso: EchoJsonServer [nome-do-pipe] }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ELSE}
  {$APPTYPE CONSOLE}
{$ENDIF}

uses
  {$IFDEF FPC}
    {$IFDEF UNIX}
  cthreads, // threads reais no Unix: sem isso os eventos/condvars da lib falham em runtime
    {$ENDIF}
  fpjson,
  {$ELSE}
  System.JSON,
  {$ENDIF}
  SysUtils,
  Classes,
  SyncObjs,
  Pipes.Types,
  Pipes.Server,
  Pipes.Json;

const
  PRECO_UNITARIO = 10; // fixo, so' para o sample ter uma conta para mostrar

function MakePedido(const AItem: string; AQtd: Integer): TJSONObject;
begin
  Result := TJSONObject.Create;
  {$IFDEF FPC}
  Result.Add('item', AItem);
  Result.Add('quantidade', AQtd);
  {$ELSE}
  Result.AddPair('item', AItem);
  Result.AddPair('quantidade', TJSONNumber.Create(AQtd));
  {$ENDIF}
end;

function JStr(AObj: TJSONObject; const AField: string): string;
begin
  {$IFDEF FPC}
  Result := AObj.Get(AField, '');
  {$ELSE}
  Result := AObj.GetValue<string>(AField);
  {$ENDIF}
end;

function JInt(AObj: TJSONObject; const AField: string): Integer;
begin
  {$IFDEF FPC}
  Result := AObj.Get(AField, 0);
  {$ELSE}
  Result := AObj.GetValue<Integer>(AField);
  {$ENDIF}
end;

type
  { Callbacks sao 'of object': o estado do sample vive nesta classe. }
  TEchoJsonServerApp = class
  private
    FServer: TNamedPipeServer;
    FConsoleLock: TCriticalSection;
    procedure Log(const AMsg: string);
    procedure OnMsg(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure OnReq(Sender: TObject; AConnId: TPipeConnectionId;
      const ARequest: TBytes; out AReply: TBytes);
    procedure OnConn(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnDisc(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnErr(Sender: TObject; AConnId: TPipeConnectionId;
      const AError: string);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run(const APipeName: string);
  end;

constructor TEchoJsonServerApp.Create;
begin
  inherited Create;
  FConsoleLock := TCriticalSection.Create;
end;

destructor TEchoJsonServerApp.Destroy;
begin
  FServer.Free; // Stop no destructor
  FConsoleLock.Free;
  inherited;
end;

procedure TEchoJsonServerApp.Log(const AMsg: string);
begin
  FConsoleLock.Enter;
  try
    Writeln(AMsg);
  finally
    FConsoleLock.Leave;
  end;
end;

procedure TEchoJsonServerApp.OnMsg(Sender: TObject; AConnId: TPipeConnectionId;
  const AData: TBytes);
var
  LPedido, LConfirmacao: TJSONObject;
begin
  try
    LPedido := PipeBytesToJSON(AData) as TJSONObject;
  except
    on E: EPipeJSONError do
    begin
      Log(Format('[conn %d] payload nao e JSON valido: %s', [AConnId, E.Message]));
      Exit;
    end;
  end;
  try
    Log(Format('[conn %d] pedido: %s x%d', [AConnId, JStr(LPedido, 'item'), JInt(LPedido, 'quantidade')]));

    LConfirmacao := MakePedido(JStr(LPedido, 'item'), JInt(LPedido, 'quantidade'));
    try
      {$IFDEF FPC}
      LConfirmacao.Add('status', 'recebido');
      {$ELSE}
      LConfirmacao.AddPair('status', 'recebido');
      {$ENDIF}
      try
        PipeSendJSON(FServer, AConnId, LConfirmacao);
      except
        on E: EPipeError do
          Log(Format('[conn %d] confirmacao falhou (cliente caiu?): %s', [AConnId, E.Message]));
      end;
    finally
      LConfirmacao.Free;
    end;
  finally
    LPedido.Free;
  end;
end;

procedure TEchoJsonServerApp.OnReq(Sender: TObject; AConnId: TPipeConnectionId;
  const ARequest: TBytes; out AReply: TBytes);
var
  LPedido, LReply: TJSONObject;
  LQtd: Integer;
begin
  // EPipeJSONError daqui pra baixo propaga de proposito - vira reply de erro
  // para o cliente (mesmo caminho de qualquer excecao dentro de OnRequest).
  LPedido := PipeBytesToJSON(ARequest) as TJSONObject;
  try
    LQtd := JInt(LPedido, 'quantidade');
    Log(Format('[conn %d] request: %s x%d', [AConnId, JStr(LPedido, 'item'), LQtd]));

    LReply := MakePedido(JStr(LPedido, 'item'), LQtd);
    try
      {$IFDEF FPC}
      LReply.Add('precoUnitario', PRECO_UNITARIO);
      LReply.Add('total', LQtd * PRECO_UNITARIO);
      {$ELSE}
      LReply.AddPair('precoUnitario', TJSONNumber.Create(PRECO_UNITARIO));
      LReply.AddPair('total', TJSONNumber.Create(LQtd * PRECO_UNITARIO));
      {$ENDIF}
      AReply := PipeJSONToBytes(LReply);
    finally
      LReply.Free;
    end;
  finally
    LPedido.Free;
  end;
end;

procedure TEchoJsonServerApp.OnConn(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log(Format('[conn %d] conectou (%d cliente(s))', [AConnId, FServer.ClientCount]));
end;

procedure TEchoJsonServerApp.OnDisc(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log(Format('[conn %d] desconectou (%d cliente(s))', [AConnId, FServer.ClientCount]));
end;

procedure TEchoJsonServerApp.OnErr(Sender: TObject; AConnId: TPipeConnectionId;
  const AError: string);
begin
  Log(Format('[conn %d] erro: %s', [AConnId, AError]));
end;

procedure TEchoJsonServerApp.Run(const APipeName: string);
begin
  FServer := TNamedPipeServer.Create(APipeName);
  FServer.OnMessage := OnMsg;
  FServer.OnRequest := OnReq;
  FServer.OnClientConnected := OnConn;
  FServer.OnClientDisconnected := OnDisc;
  FServer.OnError := OnErr;
  FServer.Listen; // nao-blocante: acceptor + readers em threads proprias
  Log('escutando em "' + APipeName + '" - Enter encerra');
  Readln;
  FServer.Stop; // sincrono: join de tudo, drena callbacks em voo
  Log('encerrado.');
end;

var
  App: TEchoJsonServerApp;
  PipeName: string;
begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  if ParamCount >= 1 then
    PipeName := ParamStr(1)
  else
    PipeName := 'pipes_faa_echojson';
  App := TEchoJsonServerApp.Create;
  try
    App.Run(PipeName);
  finally
    App.Free;
  end;
end.
