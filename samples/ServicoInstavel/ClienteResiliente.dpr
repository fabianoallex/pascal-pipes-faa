program ClienteResiliente;

{ Cliente robusto pro ServicoInstavel: manda N pedidos com Request/RequestText
  usando um timeout CURTO por tentativa (800 ms) e retry com backoff
  exponencial (200, 400, 800, 1600, 3200 ms), tratando cada excecao da lib de
  um jeito diferente — esse e' o ponto do sample:

    EPipeTimeout -> transitorio (servidor lento ou sobrecarregado): repete.
    EPipeClosed  -> conexao caiu no meio do pedido: repete (o AutoReconnect
                    do cliente cuida de reconectar em paralelo; so' precisa
                    dar tempo).
    EPipeError   -> erro de NEGOCIO devolvido pelo servidor (excecao no
                    OnRequest dele): repetir nao vai adiantar, entao propaga
                    na hora e o pedido e' dado como falho.

  Uso: ClienteResiliente [nome-do-pipe] [quantidade=15]
  Compila nos dois mundos a partir do MESMO fonte:
    FPC:    fpc -MDelphi -Sh -Fu..\..\src ClienteResiliente.dpr  (ou lazbuild)
    Delphi: abrir ClienteResiliente.dproj no IDE }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ELSE}
  {$APPTYPE CONSOLE}
{$ENDIF}

uses
  {$IFDEF FPC}
    {$IFDEF UNIX}
  cthreads,
    {$ENDIF}
  {$ENDIF}
  SysUtils,
  Classes,
  SyncObjs,
  Pipes.Types,
  Pipes.Client;

type
  TClienteResilienteApp = class
  private
    FClient: TNamedPipeClient;
    FConsoleLock: TCriticalSection;
    procedure Log(const AMsg: string);
    function TentarComRetry(const ATexto: string; AMaxTentativas: Integer): string;
    procedure OnConn(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnDisc(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnErr(Sender: TObject; AConnId: TPipeConnectionId;
      const AError: string);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run(const APipeName: string; AQuantidade: Integer);
  end;

constructor TClienteResilienteApp.Create;
begin
  inherited Create;
  FConsoleLock := TCriticalSection.Create;
end;

destructor TClienteResilienteApp.Destroy;
begin
  FClient.Free; // Disconnect no destructor
  FConsoleLock.Free;
  inherited;
end;

procedure TClienteResilienteApp.Log(const AMsg: string);
begin
  FConsoleLock.Enter;
  try
    Writeln(AMsg);
  finally
    FConsoleLock.Leave;
  end;
end;

function TClienteResilienteApp.TentarComRetry(const ATexto: string;
  AMaxTentativas: Integer): string;
var
  LTentativa, LEsperaMs: Integer;
begin
  LEsperaMs := 200;
  for LTentativa := 1 to AMaxTentativas do
  begin
    try
      Exit(FClient.RequestText(ATexto, 800)); // timeout curto de proposito
    except
      on E: EPipeTimeout do
        Log(Format('  tentativa %d/%d: timeout (servidor lento) - repete em %d ms',
          [LTentativa, AMaxTentativas, LEsperaMs]));
      on E: EPipeClosed do
        Log(Format('  tentativa %d/%d: conexao caiu - repete em %d ms ' +
          '(AutoReconnect cuida da reconexao)', [LTentativa, AMaxTentativas, LEsperaMs]));
      on E: EPipeError do
      begin
        // erro de negocio do servidor: repetir nao muda o resultado.
        Log('  erro de negocio do servidor (sem retry): ' + E.Message);
        raise;
      end;
    end;
    Sleep(LEsperaMs);
    LEsperaMs := LEsperaMs * 2; // backoff exponencial
  end;
  raise EPipeTimeout.CreateFmt('desistiu depois de %d tentativas', [AMaxTentativas]);
end;

procedure TClienteResilienteApp.OnConn(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log('conectado.');
end;

procedure TClienteResilienteApp.OnDisc(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log('conexao caiu - AutoReconnect tentando...');
end;

procedure TClienteResilienteApp.OnErr(Sender: TObject; AConnId: TPipeConnectionId;
  const AError: string);
begin
  Log('erro: ' + AError);
end;

procedure TClienteResilienteApp.Run(const APipeName: string; AQuantidade: Integer);
var
  I: Integer;
  LResultado: string;
  LSucessos, LFalhas: Integer;
begin
  FClient := TNamedPipeClient.Create(APipeName);
  FClient.AutoReconnect := True;
  FClient.OnConnected := OnConn;
  FClient.OnDisconnected := OnDisc;
  FClient.OnError := OnErr;
  Log('conectando em "' + APipeName + '"...');
  FClient.Connect(3000);

  LSucessos := 0;
  LFalhas := 0;
  for I := 1 to AQuantidade do
  begin
    Log(Format('pedido %d: enviando...', [I]));
    try
      LResultado := TentarComRetry('pedido-' + IntToStr(I), 5);
      Inc(LSucessos);
      Log(Format('pedido %d: OK -> %s', [I, LResultado]));
    except
      on E: EPipeError do
      begin
        Inc(LFalhas);
        Log(Format('pedido %d: FALHOU -> %s', [I, E.Message]));
      end;
    end;
    Sleep(150); // so' pro log ficar legivel; nao e' parte da robustez em si
  end;

  Log(Format('fim: %d sucesso(s), %d falha(s) de %d pedido(s).',
    [LSucessos, LFalhas, AQuantidade]));
  FClient.Disconnect;
end;

var
  App: TClienteResilienteApp;
  PipeName: string;
  Quantidade: Integer;
begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  if ParamCount >= 1 then
    PipeName := ParamStr(1)
  else
    PipeName := 'pipes_faa_servico';
  Quantidade := 15;
  if ParamCount >= 2 then
    Quantidade := StrToIntDef(ParamStr(2), 15);
  App := TClienteResilienteApp.Create;
  try
    App.Run(PipeName, Quantidade);
  finally
    App.Free;
  end;
end.
