unit Pipes.FinalizationCheck;

{ Checagem da ordem de finalizacao do PipeGroupDispatcher global contra o
  PcPool da pascal-common-faa, rodada a cada execucao da suite unitaria.

  Pipes.Threading e' finalizada ANTES de PascalCommon.ThreadPool (usa-a), entao
  o PipeGroupDispatcher e' liberado com PcPool ainda vivo e possivelmente com
  TPipeMailboxDrainWork em voo nele. TPipeKeyedDispatcher.Destroy tem de
  esperar essas drenagens; sem a espera, ele liberaria as mailboxes com itens
  pendentes (que nunca rodariam) enquanto a drenagem ainda chamaria Fetch num
  dispatcher ja liberado (use-after-free).

  Como prova: a finalization de Pipes.ThreadingTests (que roda antes da de
  Pipes.Threading) enfileira GFinalizationQueued itens lentos numa chave do
  PipeGroupDispatcher, e cada item soma 1 em GFinalizationRan. A finalization
  DESTA unit roda logo depois da de Pipes.Threading — para isso esta unit
  usa so' units da pascal-common-faa e vem ANTES de qualquer unit do pipes no
  uses do programa (.dpr/.lpr), sendo inicializada antes de Pipes.Threading e
  finalizada depois dela. Se nem todo item tiver rodado quando o dispatcher
  terminou de ser liberado, imprime "FINALIZATION CHECK FAILED" e poe
  ExitCode = 1 (mesmo protocolo de PascalCommon.ThreadPoolTests).

  Sem framework de teste: o mesmo arquivo serve ao DUnitX e ao FPCUnit (a copia
  em tests/Unit/fpc e' identica). }

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

interface

uses
  PascalCommon.Threading,
  PascalCommon.ThreadPool;

var
  /// Itens que a finalization de Pipes.ThreadingTests enfileirou.
  GFinalizationQueued: Integer;
  /// Itens que de fato rodaram (atomico: somado pelos workers do PcPool).
  GFinalizationRan: Integer;

implementation

uses
  SysUtils;

procedure Report(const AMsg: string);
begin
  ExitCode := 1;
  try
    WriteLn(ErrOutput, 'FINALIZATION CHECK FAILED (Pipes.FinalizationCheck): ', AMsg);
  except
    // runner GUI sem console: o ExitCode ja registra a falha
  end;
end;

procedure CheckGroupDispatcherDrained;
var
  LRan: Integer;
begin
  if GFinalizationQueued = 0 then
  begin
    Report('nenhum item foi enfileirado (Pipes.ThreadingTests nao finalizou antes?)');
    Exit;
  end;
  LRan := PcAtomicGet(GFinalizationRan);
  if LRan <> GFinalizationQueued then
    Report(Format('PipeGroupDispatcher liberado com drenagem em voo: rodaram %d de %d itens',
      [LRan, GFinalizationQueued]));
  if PcPool = nil then
    Report('PcPool ja liberado antes desta finalization');
end;

initialization
  // vazia: o Delphi so aceita finalization depois de uma initialization

finalization
  CheckGroupDispatcherDrained;

end.
