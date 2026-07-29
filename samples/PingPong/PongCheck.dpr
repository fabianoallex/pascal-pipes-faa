program PongCheck;

{ Verificacao headless do nucleo do PingPong. Console, sem janela, sem rede.

  POR QUE ISTO EXISTE, E POR QUE ELE MORA AQUI E NAO EM tests/

  tests/ testa a BIBLIOTECA. Isto testa a logica de UM sample, e a licao que
  ele carrega e' sobre o sample: como se verifica uma simulacao de tempo real
  sem abrir a janela e sem esperar o relogio.

  A chave e' que o PingPong separa o jogo da apresentacao. Pong.Partida (a
  fisica), Pong.Protocolo (o fio) e Pong.Ia (o bot) nao usam nem a UI nem a
  biblioteca de pipes — repare no uses abaixo: SysUtils e mais nada. Por isso
  este programa consegue chamar Avancar num laco `for` em vez de esperar 16ms
  por passo, e roda ~40 MINUTOS de jogo simulado em menos de um segundo. Foi
  assim que se descobriu que dois bots "medio" empatavam por dez minutos: nao
  daria para notar isso jogando.

  Se a fisica dependesse do TCanvas, ou o protocolo do TPipeClient, nada disto
  seria possivel — e' o argumento pratico para a separacao que o sample prega.

  O QUE ELE NAO COBRE, e vale saber:

    - nada de uPongMain.pas: acumulador de tempo, teclado, pintura, OI,
      reconexao, ligacao do bot, congelamento por falta de sinal;
    - nada da biblioteca: ChecarPrevisao faz Encode -> Decode em memoria, nao
      passa por socket nenhum. Nao ha um TPipeServer neste arquivo.

  E' teste do NUCLEO PURO. Que ele chega certo na tela do outro lado e' outro
  assunto — esse ainda se verifica abrindo duas janelas.

  SOBRE A SEMENTE: RandSeed fixo, nao Randomize. O unico Random do jogo e' o
  angulo do saque, e com ele solto uma falha aparecia numa execucao e sumia na
  seguinte. Fixo, uma falha e' reproduzivel. Os numeros impressos NAO batem
  entre Delphi e FPC (os geradores sao diferentes) — por isso as asseroes
  duras sao estruturais ("termina", "ninguem fica em zero", "o rally nao passa
  de N"), e as medias de rebatida sao informativas. }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}
{$APPTYPE CONSOLE}

uses
  SysUtils, DateUtils,
  Pong.Partida in 'Pong.Partida.pas',
  Pong.Protocolo in 'Pong.Protocolo.pas',
  Pong.Ia in 'Pong.Ia.pas';

const
  SEMENTE = 20260729;

  // Passos por segundo de jogo (1 / PONG_DT).
  PASSOS_POR_SEGUNDO = 62;

  // Teto de rebatidas por ponto. Nao e' medida de qualidade do bot: e' o
  // detector do bug que motivou este arquivo — um bot que sempre alcanca a
  // bola faz o rally nao terminar nunca. Medido no FPC: ~8 (facil), ~11
  // (medio), ~20 (dificil). O teto e' folgado de proposito.
  TETO_REBATIDAS_POR_PONTO = 60;

  PARTIDAS_POR_NIVEL = 3;

var
  GTicksSimulados: Int64;

procedure Falhar(const AMensagem: string);
begin
  raise Exception.Create(AMensagem);
end;

procedure FalharFmt(const AMensagem: string; const AArgs: array of const);
begin
  raise Exception.CreateFmt(AMensagem, AArgs);
end;

{ Um passo da autoridade com os dois lados no automatico. }
procedure PassoComBots(APartida: TPongPartida; ADif: TPongDificuldade);
var
  LE: TPongEstado;
begin
  APartida.Capturar(LE);
  APartida.DefinirEntrada(0, PongIaDirecao(LE, 0, ADif));
  APartida.DefinirEntrada(1, PongIaDirecao(LE, 1, ADif));
  APartida.Avancar;
  Inc(GTicksSimulados);
end;

{ --- 1. protocolo: o que entra no fio tem que voltar igual --- }

procedure ChecarProtocolo;
var
  LP: TPongPartida;
  LA, LB: TPongEstado;
  LLinha, LAp0, LAp1: string;
  LIdx: Integer;
begin
  LP := TPongPartida.Create(True);
  try
    LP.Retomar;
    LP.DefinirEntrada(0, -1);
    LP.DefinirEntrada(1, 1);
    for LIdx := 1 to 400 do
    begin
      LP.Avancar;
      Inc(GTicksSimulados);
    end;
    LP.Capturar(LA);
  finally
    LP.Free;
  end;

  // O apelido leva um separador no meio de proposito: Sanear tem que neutralizar.
  LLinha := PongEncodeEstado(LA, 'Hospede|iro', 'Convidado');
  WriteLn(Format('  ESTADO ocupa %d bytes de texto (+20 do cabecalho NPF1)',
    [Length(LLinha)]));
  if PongMsgKindOf(LLinha) <> pmkEstado then
    Falhar('PongMsgKindOf nao reconheceu o proprio ESTADO');

  PongDecodeEstado(LLinha, LB, LAp0, LAp1);
  if LAp0 <> 'Hospede iro' then
    Falhar('Sanear deixou passar um separador: "' + LAp0 + '"');
  if LB.Tick <> LA.Tick then
    Falhar('tick nao sobreviveu ao round-trip');
  if LB.Fase <> LA.Fase then
    Falhar('fase nao sobreviveu ao round-trip');
  if LB.EsperaMs <> LA.EsperaMs then
    Falhar('EsperaMs nao sobreviveu ao round-trip');

  // Ponto fixo em centesimos: a tolerancia e' o proprio passo da escala.
  if Abs(LB.BolaX - LA.BolaX) > 0.01 then
    Falhar('BolaX nao sobreviveu ao round-trip');
  if Abs(LB.BolaY - LA.BolaY) > 0.01 then
    Falhar('BolaY nao sobreviveu ao round-trip');
  if Abs(LB.VelX - LA.VelX) > 0.01 then
    Falhar('VelX nao sobreviveu ao round-trip');
  if Abs(LB.VelY - LA.VelY) > 0.01 then
    Falhar('VelY nao sobreviveu ao round-trip');

  for LIdx := 0 to 1 do
  begin
    if Abs(LB.RaqueteY[LIdx] - LA.RaqueteY[LIdx]) > 0.01 then
      FalharFmt('RaqueteY[%d] nao sobreviveu ao round-trip', [LIdx]);
    if LB.Entrada[LIdx] <> LA.Entrada[LIdx] then
      FalharFmt('Entrada[%d] nao sobreviveu ao round-trip', [LIdx]);
    if LB.Placar[LIdx] <> LA.Placar[LIdx] then
      FalharFmt('Placar[%d] nao sobreviveu ao round-trip', [LIdx]);
  end;
  WriteLn('  round-trip do ESTADO: ok (todos os campos)');

  // Normalizacao defensiva: a direcao vem de outro processo. Sem isto, um
  // cliente com bug (ou com ma fe) andaria 50 vezes mais rapido que todo mundo.
  if PongDecodeEntrada('ENTRADA|50') <> 1 then
    Falhar('ENTRADA fora da faixa nao foi normalizada');
  if PongDecodeEntrada('ENTRADA|-99') <> -1 then
    Falhar('ENTRADA fora da faixa nao foi normalizada');
  WriteLn('  ENTRADA fora da faixa normalizada para -1/0/+1: ok');
end;

{ --- 2. o espelho preve, mas nao decide --- }

procedure ChecarEspelhoNaoDecide;
var
  LAut, LEsp: TPongPartida;
  LE: TPongEstado;
  LIdx: Integer;
begin
  LAut := TPongPartida.Create(True);
  LEsp := TPongPartida.Create(False);
  try
    LAut.Retomar;
    LAut.Capturar(LE);
    LEsp.Aplicar(LE);

    // 15 segundos sem NENHUM snapshot: tempo de sobra para varios pontos.
    for LIdx := 1 to PASSOS_POR_SEGUNDO * 15 do
    begin
      PassoComBots(LAut, pdMedio);
      LEsp.Avancar; // preve sozinho, as cegas
    end;

    WriteLn(Format(
      '  15s sem snapshot: autoridade %d x %d, espelho %d x %d',
      [LAut.Placar[0], LAut.Placar[1], LEsp.Placar[0], LEsp.Placar[1]]));

    if LAut.Placar[0] + LAut.Placar[1] = 0 then
      Falhar('a autoridade nao pontuou: o cenario nao testou nada');
    if (LEsp.Placar[0] <> 0) or (LEsp.Placar[1] <> 0) then
      Falhar('o espelho pontuou sozinho - a autoridade nao e mais unica');
  finally
    LEsp.Free;
    LAut.Free;
  end;
end;

{ --- 3. quanto a tela do convidado erra entre duas correcoes --- }

{ Autoridade e espelho lado a lado, com snapshots REAIS no meio (Encode ->
  string -> Decode -> Aplicar) a cada ATicksPorSnapshot passos. Mede, nos ticks
  entre um snapshot e o proximo, a distancia entre a bola das duas — que e'
  literalmente o erro que o jogador ve na tela.

  AComEntrada = False simula um ESTADO que NAO carregasse a direcao das
  raquetes, para mostrar o que aquele campo de dois inteiros compra. }
procedure MedirPrevisao(ATicksPorSnapshot: Integer; AComEntrada: Boolean;
  AExigir: Boolean);
var
  LAut, LEsp: TPongPartida;
  LE, LF: TPongEstado;
  LLinha, LRotulo, LAp0, LAp1: string;
  LIdx, LDesde, LPontos: Integer;
  LErro, LMaxBola, LMaxRaquete: Double;
begin
  LAut := TPongPartida.Create(True);
  LEsp := TPongPartida.Create(False);
  try
    LAut.Retomar;
    LMaxBola := 0;
    LMaxRaquete := 0;
    LDesde := 0;

    for LIdx := 1 to PASSOS_POR_SEGUNDO * 120 do // 2 minutos de jogo
    begin
      PassoComBots(LAut, pdMedio);
      LEsp.Avancar;
      Inc(LDesde);

      if LDesde < ATicksPorSnapshot then
      begin
        // Ainda sem correcao: e' aqui que mora o erro visivel.
        LAut.Capturar(LE);
        LEsp.Capturar(LF);
        if LE.Fase = pfJogando then
        begin
          LErro := Sqrt(Sqr(LE.BolaX - LF.BolaX) + Sqr(LE.BolaY - LF.BolaY));
          if LErro > LMaxBola then
            LMaxBola := LErro;
        end;
        LErro := Abs(LE.RaqueteY[1] - LF.RaqueteY[1]);
        if LErro > LMaxRaquete then
          LMaxRaquete := LErro;
        Continue;
      end;

      LDesde := 0;
      LAut.Capturar(LE);
      LLinha := PongEncodeEstado(LE, 'H', 'C');
      PongDecodeEstado(LLinha, LF, LAp0, LAp1);
      if not AComEntrada then
      begin
        LF.Entrada[0] := 0;
        LF.Entrada[1] := 0;
      end;
      LEsp.Aplicar(LF);
    end;

    LAut.Capturar(LE);
    LPontos := LE.Placar[0] + LE.Placar[1];

    if AComEntrada then
      LRotulo := 'ESTADO com a direcao'
    else
      LRotulo := 'ESTADO SEM a direcao';
    WriteLn(Format(
      '  %s @%2d ticks (%2.0f snapshots/s): bola erra ate %5.1f un, ' +
      'raquete ate %5.1f un (%.0f%% de uma raquete)',
      [LRotulo, ATicksPorSnapshot, 1 / (ATicksPorSnapshot * PONG_DT),
       LMaxBola, LMaxRaquete, 100 * LMaxRaquete / PONG_RAQUETE_ALTURA]));

    if LPontos = 0 then
      Falhar('a partida de medicao nem andou');
    if not AExigir then
      Exit; // linha de comparacao: ela DEVE divergir, e' esse o ponto

    // Com snapshot curto a fisica dos dois lados e' a mesma conta com os
    // mesmos numeros: o erro da bola tem que ser ~zero.
    if LMaxBola > 1 then
      FalharFmt('previsao da bola divergiu %.1f un da autoridade', [LMaxBola]);
    // Teto teorico da raquete: por tick previsto sem correcao, a direcao do
    // adversario pode ter INVERTIDO (delta 2), logo 2*V*DT por tick.
    if LMaxRaquete > ATicksPorSnapshot * 2 * PONG_RAQUETE_VELOCIDADE * PONG_DT then
      FalharFmt('raquete prevista atrasou %.1f un, mais que o teto teorico',
        [LMaxRaquete]);
  finally
    LEsp.Free;
    LAut.Free;
  end;
end;

{ --- 4. o bot fecha ponto, e a partida acaba --- }

{ Uma partida inteira bot contra bot, contando rebatidas e conferindo
  invariantes duras a cada passo. Devolve rebatidas por ponto. }
function RodarPartida(ADif: TPongDificuldade): Double;
var
  LP: TPongPartida;
  LE: TPongEstado;
  LTicks, LLimite, LSinal, LRebatidas, LPontos: Integer;
begin
  LP := TPongPartida.Create(True);
  try
    LP.Retomar;
    LLimite := PASSOS_POR_SEGUNDO * 900; // 15 minutos de jogo
    LTicks := 0;
    LSinal := 0;
    LRebatidas := 0;

    while (LP.Fase <> pfTerminada) and (LTicks < LLimite) do
    begin
      PassoComBots(LP, ADif);
      Inc(LTicks);
      LP.Capturar(LE);

      // Rebatida = a bola inverteu o sentido horizontal.
      if (LE.Fase = pfJogando) and (LE.VelX <> 0) then
      begin
        if (LSinal <> 0) and ((LSinal > 0) <> (LE.VelX > 0)) then
          Inc(LRebatidas);
        if LE.VelX > 0 then
          LSinal := 1
        else
          LSinal := -1;
      end;

      // Invariantes que nenhuma jogada pode violar.
      if (LE.BolaY < -1) or (LE.BolaY > PONG_MUNDO_ALTURA + 1) then
        FalharFmt('a bola atravessou o teto/chao: Y=%.2f', [LE.BolaY]);
      if (LE.RaqueteY[0] < PONG_RAQUETE_ALTURA / 2 - 0.01) or
         (LE.RaqueteY[0] > PONG_MUNDO_ALTURA - PONG_RAQUETE_ALTURA / 2 + 0.01) then
        FalharFmt('a raquete 0 saiu do campo: Y=%.2f', [LE.RaqueteY[0]]);
    end;

    LPontos := LP.Placar[0] + LP.Placar[1];
    if LPontos = 0 then
      FalharFmt('ninguem marcou ponto em %.0fs de jogo - o bot esta alcancando ' +
        'tudo (ver o horizonte de reacao em Pong.Ia.pas)', [LTicks * PONG_DT]);
    if LP.Fase <> pfTerminada then
      FalharFmt('a partida nao terminou em %.0fs de jogo', [LTicks * PONG_DT]);

    Result := LRebatidas / LPontos;
  finally
    LP.Free;
  end;
end;

procedure ChecarNivel(ADif: TPongDificuldade; const ANome: string);
var
  LIdx: Integer;
  LSoma, LMin, LMax, LAtual: Double;
begin
  LSoma := 0;
  LMin := 1E30;
  LMax := 0;
  for LIdx := 1 to PARTIDAS_POR_NIVEL do
  begin
    LAtual := RodarPartida(ADif);
    LSoma := LSoma + LAtual;
    if LAtual < LMin then
      LMin := LAtual;
    if LAtual > LMax then
      LMax := LAtual;
  end;

  WriteLn(Format('  %-8s %d partidas ate o fim, %.1f rebatidas por ponto ' +
    '(entre %.1f e %.1f)',
    [ANome, PARTIDAS_POR_NIVEL, LSoma / PARTIDAS_POR_NIVEL, LMin, LMax]));

  if LMax > TETO_REBATIDAS_POR_PONTO then
    FalharFmt('%s: %.1f rebatidas por ponto passa do teto de %d - o rally nao ' +
      'esta fechando', [ANome, LMax, TETO_REBATIDAS_POR_PONTO]);
end;

var
  GInicio: TDateTime;
  GMs: Int64;
begin
  // Ver o cabecalho: semente fixa, nao Randomize.
  RandSeed := SEMENTE;
  GTicksSimulados := 0;
  GInicio := Now;

  try
    WriteLn('PongCheck - verificacao headless do nucleo do PingPong');
    WriteLn;
    WriteLn('1. protocolo');
    ChecarProtocolo;
    WriteLn;
    WriteLn('2. o espelho preve, mas nao decide');
    ChecarEspelhoNaoDecide;
    WriteLn;
    WriteLn('3. erro da previsao entre duas correcoes');
    MedirPrevisao(2, True, True);    // o que o sample usa
    MedirPrevisao(2, False, False);  // o mesmo, sem a direcao no snapshot
    MedirPrevisao(10, True, False);  // rede ruim: 6 snapshots por segundo
    MedirPrevisao(10, False, False);
    WriteLn;
    WriteLn('4. o bot fecha ponto e a partida acaba');
    ChecarNivel(pdFacil, 'facil');
    ChecarNivel(pdMedio, 'medio');
    ChecarNivel(pdDificil, 'dificil');

    GMs := MilliSecondsBetween(Now, GInicio);
    if GMs <= 0 then
      GMs := 1;
    WriteLn;
    WriteLn(Format('%.0f minutos de jogo simulados em %d ms (%.0fx tempo real).',
      [GTicksSimulados * PONG_DT / 60, GMs,
       (GTicksSimulados * PONG_DT * 1000) / GMs]));
    WriteLn('TUDO OK');
  except
    on E: Exception do
    begin
      WriteLn;
      WriteLn('FALHOU: ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
