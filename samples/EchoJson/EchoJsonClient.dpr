program EchoJsonClient;

{ Cliente de eco console com payload JSON (ver EchoJsonServer.dpr e
  README.md secao "JSON"). Le linhas do teclado no formato "item quantidade":
    cafe 2      -> PipeSendJSON (fire-and-forget); a confirmacao assincrona
                   do servidor chega via OnMessage, numa thread do pool
    ?cafe 2     -> PipeRequestJSON (RPC sincrono com timeout de 5 s); o reply
                   (com total calculado) chega como retorno da chamada
    sair        -> encerra (linha vazia tambem)

  Compila nos dois mundos a partir do MESMO fonte:
    FPC:    fpc -MDelphi -Sh -Fu..\..\src EchoJsonClient.dpr  (ou lazbuild EchoJsonClient.lpi)
    Delphi: abrir EchoJsonClient.dproj no IDE

  Uso: EchoJsonClient [nome-do-pipe] }

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
  Pipes.Client,
  Pipes.Json;

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
  TEchoJsonClientApp = class
  private
    FClient: TNamedPipeClient;
    FConsoleLock: TCriticalSection;
    procedure Log(const AMsg: string);
    procedure OnMsg(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure OnConn(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnDisc(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnErr(Sender: TObject; AConnId: TPipeConnectionId;
      const AError: string);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run(const APipeName: string);
  end;

constructor TEchoJsonClientApp.Create;
begin
  inherited Create;
  FConsoleLock := TCriticalSection.Create;
end;

destructor TEchoJsonClientApp.Destroy;
begin
  FClient.Free; // Disconnect no destructor
  FConsoleLock.Free;
  inherited;
end;

procedure TEchoJsonClientApp.Log(const AMsg: string);
begin
  FConsoleLock.Enter;
  try
    Writeln(AMsg);
  finally
    FConsoleLock.Leave;
  end;
end;

procedure TEchoJsonClientApp.OnMsg(Sender: TObject; AConnId: TPipeConnectionId;
  const AData: TBytes);
var
  LConfirmacao: TJSONObject;
begin
  try
    LConfirmacao := PipeBytesToJSON(AData) as TJSONObject;
  except
    on E: EPipeJSONError do
    begin
      Log('confirmacao nao e JSON valido: ' + E.Message);
      Exit;
    end;
  end;
  try
    Log(Format('confirmacao assincrona: %s x%d (%s)',
      [JStr(LConfirmacao, 'item'), JInt(LConfirmacao, 'quantidade'),
       JStr(LConfirmacao, 'status')]));
  finally
    LConfirmacao.Free;
  end;
end;

procedure TEchoJsonClientApp.OnConn(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log('conectado.');
end;

procedure TEchoJsonClientApp.OnDisc(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log('desconectado do servidor.');
end;

procedure TEchoJsonClientApp.OnErr(Sender: TObject; AConnId: TPipeConnectionId;
  const AError: string);
begin
  Log('erro: ' + AError);
end;

procedure TEchoJsonClientApp.Run(const APipeName: string);
var
  LLinha, LItem: string;
  LQtd, LEspaco: Integer;
  LSincrono: Boolean;
  LPedido, LReply: TJSONObject;
begin
  FClient := TNamedPipeClient.Create(APipeName);
  FClient.OnMessage := OnMsg;
  FClient.OnConnected := OnConn;
  FClient.OnDisconnected := OnDisc;
  FClient.OnError := OnErr;
  FClient.Connect(5000); // re-tenta ate 5 s (cobre servidor ainda subindo)
  Log('conectado a "' + APipeName + '". Digite "item qtd" (assincrono), ' +
    '"?item qtd" (RPC) ou "sair".');
  while True do
  begin
    Readln(LLinha);
    if (LLinha = '') or SameText(LLinha, 'sair') then
      Break;

    LSincrono := (LLinha[1] = '?');
    if LSincrono then
      Delete(LLinha, 1, 1);

    LEspaco := LastDelimiter(' ', LLinha);
    if (LEspaco = 0) or not TryStrToInt(Copy(LLinha, LEspaco + 1, MaxInt), LQtd) then
    begin
      Log('formato esperado: item quantidade (ex.: cafe 2)');
      Continue;
    end;
    LItem := Trim(Copy(LLinha, 1, LEspaco - 1));

    LPedido := MakePedido(LItem, LQtd);
    try
      try
        if LSincrono then
        begin
          LReply := PipeRequestJSON(FClient, LPedido, 5000) as TJSONObject;
          try
            Log(Format('reply sincrono: %s x%d = %d (preco unitario %d)',
              [JStr(LReply, 'item'), JInt(LReply, 'quantidade'),
               JInt(LReply, 'total'), JInt(LReply, 'precoUnitario')]));
          finally
            LReply.Free;
          end;
        end
        else
          PipeSendJSON(FClient, LPedido);
      except
        on E: EPipeError do
          Log('falha no envio: ' + E.Message);
      end;
    finally
      LPedido.Free;
    end;
  end;
  FClient.Disconnect; // sincrono e idempotente
  Log('encerrado.');
end;

var
  App: TEchoJsonClientApp;
  PipeName: string;
begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  if ParamCount >= 1 then
    PipeName := ParamStr(1)
  else
    PipeName := 'pipes_faa_echojson';
  App := TEchoJsonClientApp.Create;
  try
    App.Run(PipeName);
  finally
    App.Free;
  end;
end.
