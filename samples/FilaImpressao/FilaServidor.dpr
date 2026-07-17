program FilaServidor;

{ Demonstra a diferenca entre pdmPool (padrao) e pdmSerialized na pratica: um
  handler "ingenuo", com estado compartilhado SEM lock (FBusy/FProximoJob),
  processa jobs que chegam em sequencia de um unico cliente. Isso e' de
  proposito — o objetivo e' expor a race, nao evita-la. Cada job dorme um
  tempo aleatorio pra alargar a janela de corrida.

  Sob pdmSerialized (padrao deste sample) nunca ha reentrancia e a ordem de
  CONCLUSAO dos jobs bate com a ordem de CHEGADA. Sob pdmPool, com varios
  workers do pool processando jobs em paralelo, o mesmo estado desprotegido
  vai flagrar reentrancia e jobs concluindo fora de ordem (quem pegou um
  sleep curto termina antes de quem pegou um sleep longo, mesmo tendo
  chegado depois).

  Em codigo de producao o certo e' sempre proteger estado compartilhado
  entre handlers (lock ou fila propria), goste ou nao do DispatchMode; este
  sample so usa a ausencia de lock como instrumento de medicao.

  Uso: FilaServidor [nome-do-pipe] [pool|serialized]
  Compila nos dois mundos a partir do MESMO fonte:
    FPC:    fpc -MDelphi -Sh -Fu..\..\src FilaServidor.dpr  (ou lazbuild)
    Delphi: abrir FilaServidor.dproj no IDE }

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
  {$ENDIF}
  SysUtils,
  Classes,
  SyncObjs,
  Pipes.Types,
  Pipes.Threading,
  Pipes.Framing,
  Pipes.Server;

type
  TFilaServidorApp = class
  private
    FServer: TNamedPipeServer;
    FConsoleLock: TCriticalSection;
    FBusy: Integer;         // atomico: detector de reentrancia (nao e' lock!)
    FProximoJob: Integer;   // "ingenuo": mexido sem protecao de proposito
    FReentrancias: Integer;
    FForaDeOrdem: Integer;
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
    procedure Run(const APipeName: string; AModoSerializado: Boolean);
  end;

constructor TFilaServidorApp.Create;
begin
  inherited Create;
  FConsoleLock := TCriticalSection.Create;
  FProximoJob := 1;
end;

destructor TFilaServidorApp.Destroy;
begin
  FServer.Free; // Stop no destructor
  FConsoleLock.Free;
  inherited;
end;

procedure TFilaServidorApp.Log(const AMsg: string);
begin
  FConsoleLock.Enter;
  try
    Writeln(AMsg);
  finally
    FConsoleLock.Leave;
  end;
end;

procedure TFilaServidorApp.OnMsg(Sender: TObject; AConnId: TPipeConnectionId;
  const AData: TBytes);
var
  LJob: Integer;
  LJaOcupado: Boolean;
begin
  LJob := StrToIntDef(PipeUtf8Decode(AData), -1);

  // Deteccao de reentrancia: CAS sem lock de verdade. Sob pdmSerialized isto
  // NUNCA acusa concorrencia (so um handler roda por vez); sob pdmPool vai
  // acusar quando dois workers caem aqui ao mesmo tempo.
  LJaOcupado := PipeAtomicCompareExchange(FBusy, 1, 0) <> 0;
  if LJaOcupado then
  begin
    PipeAtomicInc(FReentrancias);
    Log(Format('  !!! job %d comecou com OUTRO handler ainda em andamento ' +
      '(concorrencia real) !!!', [LJob]));
  end;
  try
    Sleep(50 + Random(300)); // trabalho de duracao variavel: alarga a corrida

    if LJob <> FProximoJob then
    begin
      PipeAtomicInc(FForaDeOrdem);
      Log(Format('job %d concluido FORA DE ORDEM (esperava %d)', [LJob, FProximoJob]));
    end
    else
      Log(Format('job %d concluido em ordem', [LJob]));
    FProximoJob := LJob + 1; // segue comparando a partir daqui mesmo se furou
  finally
    if not LJaOcupado then
      PipeAtomicSet(FBusy, 0);
  end;
end;

procedure TFilaServidorApp.OnConn(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log(Format('[conn %d] conectou', [AConnId]));
end;

procedure TFilaServidorApp.OnDisc(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log(Format('[conn %d] desconectou', [AConnId]));
end;

procedure TFilaServidorApp.OnErr(Sender: TObject; AConnId: TPipeConnectionId;
  const AError: string);
begin
  Log(Format('[conn %d] erro: %s', [AConnId, AError]));
end;

procedure TFilaServidorApp.Run(const APipeName: string; AModoSerializado: Boolean);
begin
  Randomize;
  FServer := TNamedPipeServer.Create(APipeName);
  if AModoSerializado then
    FServer.DispatchMode := pdmSerialized
  else
    FServer.DispatchMode := pdmPool; // padrao, so explicito pra clareza no log
  FServer.OnMessage := OnMsg;
  FServer.OnClientConnected := OnConn;
  FServer.OnClientDisconnected := OnDisc;
  FServer.OnError := OnErr;
  FServer.Listen;
  if AModoSerializado then
    Log('modo: pdmSerialized (1 worker, FIFO) - escutando em "' + APipeName + '"')
  else
    Log('modo: pdmPool (varios workers concorrentes) - escutando em "' + APipeName + '"');
  Log('rode FilaCliente noutro terminal para disparar os jobs. Enter encerra.');
  Readln;
  FServer.Stop;
  Log(Format('encerrado. reentrancias detectadas: %d, jobs fora de ordem: %d.',
    [FReentrancias, FForaDeOrdem]));
end;

var
  App: TFilaServidorApp;
  PipeName: string;
  Serializado: Boolean;
begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  if ParamCount >= 1 then
    PipeName := ParamStr(1)
  else
    PipeName := 'pipes_faa_fila';
  Serializado := (ParamCount < 2) or SameText(ParamStr(2), 'serialized');
  App := TFilaServidorApp.Create;
  try
    App.Run(PipeName, Serializado);
  finally
    App.Free;
  end;
end.
