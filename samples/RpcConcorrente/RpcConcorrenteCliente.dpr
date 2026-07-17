program RpcConcorrenteCliente;

{ Prova a garantia documentada no README: "chamadas concorrentes de varias
  threads no mesmo cliente sao suportadas". Aqui varias TThread compartilham
  a MESMA instancia de TNamedPipeClient e chamam RequestText ao mesmo tempo,
  de dentro de suas proprias threads (a chamada bloqueia quem chamou, nunca a
  thread de leitura da lib — e' o correlation id por chamada que garante que
  cada thread recebe exatamente a resposta do pedido QUE ELA fez, mesmo com
  N pedidos cruzando o pipe ao mesmo tempo).

  Cada thread manda ids unicos ("req:<id>") e confere que a resposta trouxe
  de volta o MESMO id que ela enviou e o resultado esperado pra aquele id.
  Se a lib algum dia misturar respostas entre chamadores concorrentes, isso
  aparece aqui como "CORRELACAO ERRADA" — o objetivo do sample e' expor esse
  tipo de bug, nao so demonstrar o caminho feliz.

  Uso: RpcConcorrenteCliente [nome-do-pipe] [threads=8] [pedidos-por-thread=25]
  Compila nos dois mundos a partir do MESMO fonte:
    FPC:    fpc -MDelphi -Sh -Fu..\..\src RpcConcorrenteCliente.dpr  (ou lazbuild)
    Delphi: abrir RpcConcorrenteCliente.dproj no IDE }

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
  DateUtils,
  Classes,
  SyncObjs,
  Pipes.Types,
  Pipes.Threading,
  Pipes.Client;

type
  TRpcConcorrenteClienteApp = class
  private
    FClient: TNamedPipeClient;
    FConsoleLock: TCriticalSection;
    FTotalOk: Integer;
    FTotalMismatch: Integer;
    FTotalErro: Integer;
    procedure OnConn(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnDisc(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnErr(Sender: TObject; AConnId: TPipeConnectionId;
      const AError: string);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Log(const AMsg: string);
    procedure RegistrarOk;
    procedure RegistrarMismatch;
    procedure RegistrarErro;
    procedure Run(const APipeName: string; AQtdThreads, APedidosPorThread: Integer);
  end;

  { Cada instancia representa uma thread de "usuario" chamando RPC no MESMO
    TNamedPipeClient compartilhado (FClient). Dados vem por campos, nunca por
    closure, seguindo o padrao da lib (TAMQPDeliveryWork em AMQP.Connection.pas). }
  TWorkerThread = class(TThread)
  private
    FClient: TNamedPipeClient;
    FApp: TRpcConcorrenteClienteApp;
    FThreadIdx: Integer;
    FQtdPedidos: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(AClient: TNamedPipeClient; AApp: TRpcConcorrenteClienteApp;
      AThreadIdx, AQtdPedidos: Integer);
  end;

{ TRpcConcorrenteClienteApp }

constructor TRpcConcorrenteClienteApp.Create;
begin
  inherited Create;
  FConsoleLock := TCriticalSection.Create;
end;

destructor TRpcConcorrenteClienteApp.Destroy;
begin
  FClient.Free; // Disconnect no destructor
  FConsoleLock.Free;
  inherited;
end;

procedure TRpcConcorrenteClienteApp.Log(const AMsg: string);
begin
  FConsoleLock.Enter;
  try
    Writeln(AMsg);
  finally
    FConsoleLock.Leave;
  end;
end;

procedure TRpcConcorrenteClienteApp.RegistrarOk;
begin
  PipeAtomicInc(FTotalOk);
end;

procedure TRpcConcorrenteClienteApp.RegistrarMismatch;
begin
  PipeAtomicInc(FTotalMismatch);
end;

procedure TRpcConcorrenteClienteApp.RegistrarErro;
begin
  PipeAtomicInc(FTotalErro);
end;

procedure TRpcConcorrenteClienteApp.OnConn(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log('conectado.');
end;

procedure TRpcConcorrenteClienteApp.OnDisc(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log('desconectado.');
end;

procedure TRpcConcorrenteClienteApp.OnErr(Sender: TObject; AConnId: TPipeConnectionId;
  const AError: string);
begin
  Log('erro: ' + AError);
end;

procedure TRpcConcorrenteClienteApp.Run(const APipeName: string;
  AQtdThreads, APedidosPorThread: Integer);
var
  LThreads: array of TWorkerThread;
  I: Integer;
  LInicio: TDateTime;
  LTotalPedidos: Integer;
begin
  FClient := TNamedPipeClient.Create(APipeName);
  FClient.OnConnected := OnConn;
  FClient.OnDisconnected := OnDisc;
  FClient.OnError := OnErr;
  Log('conectando em "' + APipeName + '"...');
  FClient.Connect(3000);

  Log(Format('disparando %d threads x %d pedidos = %d Requests concorrentes ' +
    'no MESMO cliente...', [AQtdThreads, APedidosPorThread, AQtdThreads * APedidosPorThread]));

  SetLength(LThreads, AQtdThreads);
  LInicio := Now;
  for I := 0 to AQtdThreads - 1 do
  begin
    LThreads[I] := TWorkerThread.Create(FClient, Self, I + 1, APedidosPorThread);
    LThreads[I].FreeOnTerminate := False;
  end;
  // Create ja inicia (FreeOnTerminate=False setado antes de qualquer chance
  // de a thread terminar sozinha); so' falta esperar todas acabarem.
  for I := 0 to AQtdThreads - 1 do
    LThreads[I].WaitFor;
  for I := 0 to AQtdThreads - 1 do
    LThreads[I].Free;

  LTotalPedidos := AQtdThreads * APedidosPorThread;
  Log(Format('fim em %d ms: %d ok, %d erro(s), %d CORRELACAO ERRADA de %d pedido(s).',
    [MilliSecondsBetween(Now, LInicio), FTotalOk, FTotalErro, FTotalMismatch, LTotalPedidos]));
  if FTotalMismatch = 0 then
    Log('nenhuma resposta cruzada entre threads: correlation id da lib se ' +
      'manteve correto sob concorrencia.')
  else
    Log('ATENCAO: respostas cruzadas entre threads (ver linhas acima) - ' +
      'isso seria um bug na lib.');

  FClient.Disconnect;
end;

{ TWorkerThread }

constructor TWorkerThread.Create(AClient: TNamedPipeClient; AApp: TRpcConcorrenteClienteApp;
  AThreadIdx, AQtdPedidos: Integer);
begin
  FClient := AClient;
  FApp := AApp;
  FThreadIdx := AThreadIdx;
  FQtdPedidos := AQtdPedidos;
  inherited Create(False); // dispara na hora
end;

procedure TWorkerThread.Execute;
const
  PREFIXO_REPLY = 'rep:';
var
  LSeq: Integer;
  LId, LEsperado, LRecebidoId, LRecebidoResultado: Int64;
  LResposta, LTexto: string;
  LResto: string;
  LPos: Integer;
begin
  for LSeq := 1 to FQtdPedidos do
  begin
    // id unico por thread+sequencia: se a lib misturar respostas entre
    // chamadores concorrentes, o id que voltar nao vai bater com este.
    LId := Int64(FThreadIdx) * 1000000 + LSeq;
    LTexto := Format('req:%d', [LId]);
    try
      LResposta := FClient.RequestText(LTexto, 5000);
      if Copy(LResposta, 1, Length(PREFIXO_REPLY)) <> PREFIXO_REPLY then
        raise Exception.CreateFmt('resposta mal formada: "%s"', [LResposta]);

      LResto := Copy(LResposta, Length(PREFIXO_REPLY) + 1, MaxInt);
      LPos := Pos(':', LResto);
      if LPos = 0 then
        raise Exception.CreateFmt('resposta mal formada: "%s"', [LResposta]);
      LRecebidoId := StrToInt64Def(Copy(LResto, 1, LPos - 1), -1);
      LRecebidoResultado := StrToInt64Def(Copy(LResto, LPos + 1, MaxInt), -1);
      LEsperado := LId * 31 + 7;

      if LRecebidoId <> LId then
      begin
        FApp.RegistrarMismatch;
        FApp.Log(Format('[thread %d] CORRELACAO ERRADA: pedi id %d, resposta veio com id %d!',
          [FThreadIdx, LId, LRecebidoId]));
      end
      else if LRecebidoResultado <> LEsperado then
      begin
        FApp.RegistrarMismatch;
        FApp.Log(Format('[thread %d] resultado errado pro id %d: esperava %d, veio %d',
          [FThreadIdx, LId, LEsperado, LRecebidoResultado]));
      end
      else
        FApp.RegistrarOk;
    except
      on E: Exception do
      begin
        FApp.RegistrarErro;
        FApp.Log(Format('[thread %d] pedido %d (id %d) falhou: %s',
          [FThreadIdx, LSeq, LId, E.Message]));
      end;
    end;
  end;
end;

var
  App: TRpcConcorrenteClienteApp;
  PipeName: string;
  QtdThreads, PedidosPorThread: Integer;
begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  if ParamCount >= 1 then
    PipeName := ParamStr(1)
  else
    PipeName := 'pipes_faa_rpc_concorrente';
  QtdThreads := 8;
  if ParamCount >= 2 then
    QtdThreads := StrToIntDef(ParamStr(2), 8);
  PedidosPorThread := 25;
  if ParamCount >= 3 then
    PedidosPorThread := StrToIntDef(ParamStr(3), 25);

  App := TRpcConcorrenteClienteApp.Create;
  try
    App.Run(PipeName, QtdThreads, PedidosPorThread);
  finally
    App.Free;
  end;
end.
