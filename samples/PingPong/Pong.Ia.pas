unit Pong.Ia;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

{ Jogador controlado pelo computador. Unit pura: le' um TPongEstado e devolve a
  DIRECAO da raquete (-1 cima, 0 parado, +1 baixo) — exatamente o mesmo valor
  que uma tecla produz.

  E' de proposito que a IA nao tenha nenhum caminho privilegiado: ela nao mexe
  na posicao da raquete, nao acelera a bola, nao sabe se esta' no hospedeiro ou
  no convidado. No convidado, a direcao que ela devolve vira uma mensagem
  ENTRADA na rede e passa pela mesma normalizacao de qualquer humano. Uma IA
  que escrevesse direto na TPongPartida seria a primeira coisa a quebrar a
  autoridade do servidor.

  A DIFERENCA PARA A IA DO PontosECaixas: la' o bot e' chamado uma vez por
  turno e "pensa" com uma pausa proposital para o humano ver a jogada. Aqui ele
  e' chamado A CADA PASSO DE SIMULACAO, junto com a fisica, porque a raquete
  dele tem que estar decidindo o tempo todo. Nao ha timer de bot neste sample.

  POR QUE ELE E' BATIVEL, e como se descobriu o que o torna bativel: a
  primeira versao usava so' a qualidade da previsao e uma zona morta, e dois
  bots "medio" jogaram DEZ MINUTOS sem marcar um ponto. A conta explica: a bola
  no teto (900 u/s) atravessa o campo em ~1,1s, e a raquete (660 u/s) percorre
  730 unidades nesse tempo — mais que a altura util do campo. Quem sabe para
  onde a bola vai SEMPRE chega, por mais rapida que ela esteja.

  O que faz o ponto acabar, entao, e' o HORIZONTE DE REACAO: cada nivel so'
  comeca a perseguir a bola quando ela esta' a menos de N unidades da propria
  raquete. Antes disso ele volta para o meio, como um jogador que ainda nao
  leu a jogada. Um horizonte curto com a bola rapida = tempo insuficiente para
  atravessar o campo, e a bola passa. Esse e' o unico botao que fecha ponto; a
  qualidade da previsao e a zona morta so' regulam o quanto ele erra FEIO.

  Nenhum dos tres niveis mexe na velocidade da raquete: um bot mais rapido que
  o jogador seria trapaca visivel na tela. }

interface

uses
  Pong.Partida;

type
  TPongDificuldade = (pdFacil, pdMedio, pdDificil);

/// Direcao (-1/0/+1) para a raquete de AJogador no estado dado.
function PongIaDirecao(const AEstado: TPongEstado; AJogador: Integer;
  ADificuldade: TPongDificuldade): Integer;

function PongDificuldadeDeIndice(AIndice: Integer): TPongDificuldade;

implementation

const
  // A que distancia da propria raquete a bola precisa chegar antes de ele
  // reagir. E' o botao que decide o placar (ver cabecalho).
  HORIZONTE: array[TPongDificuldade] of Double = (300.0, 380.0, 450.0);

  // NENHUM nivel volta ao centro enquanto espera, e isso foi medido, nao
  // escolhido por gosto: do centro o pior caso de deslocamento cai de 490 para
  // 245 unidades, o que sozinho poe qualquer horizonte razoavel dentro do
  // alcance da raquete — a versao que se reposicionava jogou uma partida
  // inteira sem levar um ponto. A raquete fica onde a jogada anterior a
  // deixou, que e' de onde vem boa parte dos pontos contra o computador.

  // Zona morta: o quanto o alvo pode estar fora do centro da raquete antes de
  // ele se mexer. Nao decide ponto sozinha, mas e' o que faz o nivel facil
  // devolver de raspao e mandar a bola para lugares esquisitos.
  ZONA_MORTA: array[TPongDificuldade] of Double = (46.0, 22.0, 9.0);

function AbsD(AValor: Double): Double;
begin
  if AValor < 0 then
    Result := -AValor
  else
    Result := AValor;
end;

{ Onde a bola vai cruzar o plano APlano, ja' contando os quiques nas paredes de
  cima e de baixo. A conta e' fechada, sem simular quadro a quadro: projeta em
  linha reta e depois "dobra" o resultado dentro da faixa util, como uma folha
  sanfonada. }
function PreverComParedes(const AEstado: TPongEstado; APlano: Double): Double;
var
  LTempo, LY, LFaixa, LCiclo: Double;
begin
  if AbsD(AEstado.VelX) < 1E-6 then
  begin
    Result := AEstado.BolaY;
    Exit;
  end;

  LTempo := (APlano - AEstado.BolaX) / AEstado.VelX;
  if LTempo < 0 then
  begin
    Result := AEstado.BolaY;
    Exit;
  end;

  LY := AEstado.BolaY + AEstado.VelY * LTempo;

  LFaixa := PONG_MUNDO_ALTURA - 2 * PONG_BOLA_RAIO;
  if LFaixa <= 0 then
  begin
    Result := PONG_MUNDO_ALTURA / 2;
    Exit;
  end;

  // Traz para o referencial [0, LFaixa] e reflete: um ciclo completo de ida e
  // volta tem 2*LFaixa.
  LY := LY - PONG_BOLA_RAIO;
  LCiclo := 2 * LFaixa;
  LY := LY - LCiclo * Int(LY / LCiclo);
  if LY < 0 then
    LY := LY + LCiclo;
  if LY > LFaixa then
    LY := LCiclo - LY;
  Result := LY + PONG_BOLA_RAIO;
end;

function PongIaDirecao(const AEstado: TPongEstado; AJogador: Integer;
  ADificuldade: TPongDificuldade): Integer;
var
  LMeuPlano, LAlvo, LZona, LTempo: Double;
  LVindoParaMim: Boolean;
begin
  Result := 0;
  if (AJogador < 0) or (AJogador > 1) then
    Exit;

  if AJogador = 0 then
  begin
    LMeuPlano := PONG_PLANO_RAQUETE0;
    LVindoParaMim := AEstado.VelX < 0;
  end
  else
  begin
    LMeuPlano := PONG_PLANO_RAQUETE1;
    LVindoParaMim := AEstado.VelX > 0;
  end;

  // Fora do horizonte (ou bola indo embora, ou jogo parado): nao ha jogada a
  // perseguir ainda.
  if (AEstado.Fase <> pfJogando) or (not LVindoParaMim) or
     (AbsD(LMeuPlano - AEstado.BolaX) > HORIZONTE[ADificuldade]) then
    Exit // fica onde esta' (Result ja' e' 0)
  else
    case ADificuldade of
      pdFacil:
        // Segue a bola CRUA, sem prever nada: contra uma bola em diagonal ele
        // esta' sempre perseguindo onde ela ESTEVE.
        LAlvo := AEstado.BolaY;
      pdMedio:
        begin
          // Extrapola em linha reta ate' o proprio plano, IGNORANDO as
          // paredes: acerta bem a bola direta e se atrapalha na que quica.
          if AbsD(AEstado.VelX) < 1E-6 then
            LAlvo := AEstado.BolaY
          else
          begin
            LTempo := (LMeuPlano - AEstado.BolaX) / AEstado.VelX;
            LAlvo := AEstado.BolaY + AEstado.VelY * LTempo;
          end;
        end;
    else
      LAlvo := PreverComParedes(AEstado, LMeuPlano);
    end;

  LZona := ZONA_MORTA[ADificuldade];
  if LAlvo > AEstado.RaqueteY[AJogador] + LZona then
    Result := 1
  else if LAlvo < AEstado.RaqueteY[AJogador] - LZona then
    Result := -1;
end;

function PongDificuldadeDeIndice(AIndice: Integer): TPongDificuldade;
begin
  case AIndice of
    0: Result := pdFacil;
    2: Result := pdDificil;
  else
    Result := pdMedio;
  end;
end;

end.
