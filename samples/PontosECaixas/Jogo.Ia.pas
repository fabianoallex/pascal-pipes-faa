unit Jogo.Ia;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

{ IA do jogador controlado pelo computador. Port da versao em Python que
  originou o sample; unit pura, sem UI e sem rede — recebe um tabuleiro e
  devolve uma aresta.

  Estrategia (heuristica de CADEIAS, sem busca completa):

  1. Se alguma jogada fecha uma caixa:
     - Havendo jogada segura em outro lugar do tabuleiro, so' fecha a caixa
       (nao ha risco de ficar sem lance neutro depois).
     - Nao havendo, a IA esta' comendo uma cadeia sem sobra de lance neutro.
       Ela simula ate onde a cadeia vai: enquanto restarem mais de 2 caixas,
       continua comendo. Quando restarem exatamente as 2 ULTIMAS caixas da
       cadeia E ainda houver tabuleiro para disputar depois, faz o
       DOUBLE-CROSS: entrega essas 2 caixas em vez de fecha-las, forcando o
       adversario a devolver o controle do jogo depois de captura-las.
  2. Sem jogada que feche caixa, joga uma aresta SEGURA (que nao deixa
     nenhuma caixa com 3 lados).
  3. Se so' restam jogadas que abrem cadeia para o adversario, abre a MENOR
     cadeia disponivel, guardando as maiores para depois.

  O passo 1 e' o que separa esta IA de uma que so' "pega o que da'": comer
  toda cadeia disponivel e' justamente como se perde o dots and boxes de
  verdade — quem come por ultimo entrega o controle. }

interface

uses
  SysUtils,
  Jogo.Partida;

/// Escolhe a jogada da IA. False quando nao ha aresta livre (fim de partida).
function JogoIaEscolherJogada(ATabuleiro: TJogoTabuleiro;
  out AAresta: TJogoAresta): Boolean;

implementation

{ Quantos lados a caixa teria DEPOIS de jogar esta aresta. }
function LadosAposJogar(ATabuleiro: TJogoTabuleiro; ALinha, AColuna: Integer): Integer;
begin
  Result := ATabuleiro.LadosPreenchidos(ALinha, AColuna) + 1;
end;

{ Separa as arestas livres em tres baldes:
    fecha  - completa alguma caixa agora
    segura - nao deixa nenhuma caixa com 3 lados (nao entrega nada)
    risco  - deixa alguma caixa com 3 lados (abre cadeia para o adversario) }
procedure Classificar(ATabuleiro: TJogoTabuleiro; const ALivres: TJogoArestas;
  out AFecha, ASegura, ARisco: TJogoArestas);
var
  LI, LJ, LQF, LQS, LQR, LLados: Integer;
  LCaixas: TJogoCaixasAdjacentes;
  LTemFecha, LTemTres: Boolean;
begin
  // Os ":= nil" antes de cada SetLength calam o falso-positivo 5091/5092 do
  // FPC com array dinamico; nao mudam o comportamento.
  AFecha := nil;
  ASegura := nil;
  ARisco := nil;
  SetLength(AFecha, Length(ALivres));
  SetLength(ASegura, Length(ALivres));
  SetLength(ARisco, Length(ALivres));
  LQF := 0;
  LQS := 0;
  LQR := 0;

  for LI := 0 to High(ALivres) do
  begin
    LCaixas := ATabuleiro.CaixasDaAresta(ALivres[LI]);
    LTemFecha := False;
    LTemTres := False;
    for LJ := 0 to LCaixas.Qtde - 1 do
    begin
      LLados := LadosAposJogar(ATabuleiro, LCaixas.Linha[LJ], LCaixas.Coluna[LJ]);
      if LLados = 4 then
        LTemFecha := True
      else if LLados = 3 then
        LTemTres := True;
    end;

    if LTemFecha then
    begin
      AFecha[LQF] := ALivres[LI];
      Inc(LQF);
    end
    else if LTemTres then
    begin
      ARisco[LQR] := ALivres[LI];
      Inc(LQR);
    end
    else
    begin
      ASegura[LQS] := ALivres[LI];
      Inc(LQS);
    end;
  end;

  SetLength(AFecha, LQF);
  SetLength(ASegura, LQS);
  SetLength(ARisco, LQR);
end;

function Sorteia(const AArestas: TJogoArestas): TJogoAresta;
begin
  Result := AArestas[Random(Length(AArestas))];
end;

{ Alguma aresta livre que feche caixa AGORA (usada para percorrer a cadeia). }
function AcharArestaQueFecha(ATabuleiro: TJogoTabuleiro;
  out AAresta: TJogoAresta): Boolean;
var
  LLivres: TJogoArestas;
  LI, LJ: Integer;
  LCaixas: TJogoCaixasAdjacentes;
begin
  Result := False;
  LLivres := ATabuleiro.ListarArestasLivres;
  for LI := 0 to High(LLivres) do
  begin
    LCaixas := ATabuleiro.CaixasDaAresta(LLivres[LI]);
    for LJ := 0 to LCaixas.Qtde - 1 do
      if ATabuleiro.LadosPreenchidos(LCaixas.Linha[LJ], LCaixas.Coluna[LJ]) = 3 then
      begin
        AAresta := LLivres[LI];
        Result := True;
        Exit;
      end;
  end;
end;

{ Simula jogar AArestaInicial e seguir capturando a cadeia ate o fim, num
  CLONE — a partida real nao e' tocada.

  Devolve quantas caixas a cadeia rende e, em ACheio, se o tabuleiro terminaria
  cheio (isto e', se nao sobra nada para disputar depois da cadeia). }
function SimularCadeia(ATabuleiro: TJogoTabuleiro;
  const AArestaInicial: TJogoAresta; out ACheio: Boolean): Integer;
var
  LSim: TJogoTabuleiro;
  LAresta: TJogoAresta;
  LTem: Boolean;
begin
  Result := 0;
  LSim := ATabuleiro.Clonar;
  try
    LAresta := AArestaInicial;
    LTem := True;
    while LTem do
    begin
      LSim.DefinirDonoAresta(LAresta, 0); // dono e' irrelevante na simulacao
      Inc(Result, LSim.FecharCaixasAdjacentes(LAresta, 0));
      LTem := AcharArestaQueFecha(LSim, LAresta);
    end;
    ACheio := LSim.TudoPreenchido;
  finally
    LSim.Free;
  end;
end;

{ Fecha DUAS caixas de uma vez — o presente que o double-cross do adversario
  deixa. Lucro puro: nao ha nada a proteger, sempre vale pegar. }
function FechaDuasCaixas(ATabuleiro: TJogoTabuleiro;
  const AAresta: TJogoAresta): Boolean;
var
  LCaixas: TJogoCaixasAdjacentes;
  LJ: Integer;
begin
  LCaixas := ATabuleiro.CaixasDaAresta(AAresta);
  Result := LCaixas.Qtde = 2;
  if not Result then
    Exit;
  for LJ := 0 to LCaixas.Qtde - 1 do
    if ATabuleiro.LadosPreenchidos(LCaixas.Linha[LJ], LCaixas.Coluna[LJ]) <> 3 then
    begin
      Result := False;
      Exit;
    end;
end;

{ Dada uma jogada que fecharia caixa, acha a aresta "de fora" da proxima caixa
  da cadeia. Jogar essa em vez do lance normal entrega as 2 ultimas caixas ao
  adversario e devolve o controle do jogo para a IA. }
function AcharArestaDeSacrificio(ATabuleiro: TJogoTabuleiro;
  const AArestaQueFecha: TJogoAresta; out AAresta: TJogoAresta): Boolean;
var
  LCaixas: TJogoCaixasAdjacentes;
  LJ: Integer;
  LTopo, LBase, LEsq, LDir: TJogoAresta;

  function Tentar(const ACandidata: TJogoAresta): Boolean;
  begin
    Result := (not JogoArestaIgual(ACandidata, AArestaQueFecha)) and
      (ATabuleiro.DonoAresta(ACandidata) = JOGO_SEM_DONO);
    if Result then
      AAresta := ACandidata;
  end;

begin
  Result := False;
  LCaixas := ATabuleiro.CaixasDaAresta(AArestaQueFecha);
  for LJ := 0 to LCaixas.Qtde - 1 do
  begin
    if ATabuleiro.LadosPreenchidos(LCaixas.Linha[LJ], LCaixas.Coluna[LJ]) <> 2 then
      Continue;
    ATabuleiro.ArestasDaCaixa(LCaixas.Linha[LJ], LCaixas.Coluna[LJ],
      LTopo, LBase, LEsq, LDir);
    if Tentar(LTopo) or Tentar(LBase) or Tentar(LEsq) or Tentar(LDir) then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

function EscolherEntreAsQueFecham(ATabuleiro: TJogoTabuleiro;
  const AFecha: TJogoArestas; ATemOutraSegura: Boolean): TJogoAresta;
var
  LPresentes: TJogoArestas;
  LI, LQtde, LCadeia: Integer;
  LCheio: Boolean;
  LSacrificio: TJogoAresta;
begin
  LPresentes := nil;
  SetLength(LPresentes, Length(AFecha));
  LQtde := 0;
  for LI := 0 to High(AFecha) do
    if FechaDuasCaixas(ATabuleiro, AFecha[LI]) then
    begin
      LPresentes[LQtde] := AFecha[LI];
      Inc(LQtde);
    end;
  SetLength(LPresentes, LQtde);
  if LQtde > 0 then
  begin
    Result := Sorteia(LPresentes);
    Exit;
  end;

  if ATemOutraSegura then
  begin
    // Ainda ha territorio neutro: comer a cadeia inteira nao deixa a IA presa
    // depois, entao nao ha motivo para sacrificar nada.
    Result := Sorteia(AFecha);
    Exit;
  end;

  Result := Sorteia(AFecha);
  LCadeia := SimularCadeia(ATabuleiro, Result, LCheio);

  // Sacrificar so' faz sentido nas 2 ultimas caixas da cadeia (com mais que
  // isso ainda da' para comer com seguranca, e a decisao e' reavaliada a cada
  // jogada) e quando a cadeia NAO e' a ultima coisa do tabuleiro — senao nao
  // ha o que proteger.
  if (LCadeia = 2) and (not LCheio) then
    if AcharArestaDeSacrificio(ATabuleiro, Result, LSacrificio) then
      Result := LSacrificio;
end;

{ So' restam lances que abrem cadeia: abre a MENOR, guardando as maiores. }
function EscolherAberturaMenosPior(ATabuleiro: TJogoTabuleiro;
  const ARisco: TJogoArestas): TJogoAresta;
var
  LI, LJ, LAbertas, LCadeia, LQtde: Integer;
  LMelhorAbertas, LMelhorCadeia: Integer;
  LCaixas: TJogoCaixasAdjacentes;
  LCheio: Boolean;
  LAbertasDe, LCadeiaDe: array of Integer;
  LMelhores: TJogoArestas;
begin
  LAbertasDe := nil;
  LCadeiaDe := nil;
  LMelhores := nil;
  SetLength(LAbertasDe, Length(ARisco));
  SetLength(LCadeiaDe, Length(ARisco));
  LMelhorAbertas := MaxInt;
  LMelhorCadeia := MaxInt;

  for LI := 0 to High(ARisco) do
  begin
    LCaixas := ATabuleiro.CaixasDaAresta(ARisco[LI]);
    LAbertas := 0;
    for LJ := 0 to LCaixas.Qtde - 1 do
      if ATabuleiro.LadosPreenchidos(LCaixas.Linha[LJ], LCaixas.Coluna[LJ]) = 2 then
        Inc(LAbertas);
    LCadeia := SimularCadeia(ATabuleiro, ARisco[LI], LCheio);
    LAbertasDe[LI] := LAbertas;
    LCadeiaDe[LI] := LCadeia;

    // Ordem lexicografica (abertas, tamanho da cadeia) — o mesmo criterio do
    // sort da versao em Python, sem precisar ordenar o vetor inteiro.
    if (LAbertas < LMelhorAbertas) or
       ((LAbertas = LMelhorAbertas) and (LCadeia < LMelhorCadeia)) then
    begin
      LMelhorAbertas := LAbertas;
      LMelhorCadeia := LCadeia;
    end;
  end;

  SetLength(LMelhores, Length(ARisco));
  LQtde := 0;
  for LI := 0 to High(ARisco) do
    if (LAbertasDe[LI] = LMelhorAbertas) and (LCadeiaDe[LI] = LMelhorCadeia) then
    begin
      LMelhores[LQtde] := ARisco[LI];
      Inc(LQtde);
    end;
  SetLength(LMelhores, LQtde);
  Result := Sorteia(LMelhores);
end;

function JogoIaEscolherJogada(ATabuleiro: TJogoTabuleiro;
  out AAresta: TJogoAresta): Boolean;
var
  LLivres, LFecha, LSegura, LRisco: TJogoArestas;
begin
  Result := False;
  LLivres := ATabuleiro.ListarArestasLivres;
  if Length(LLivres) = 0 then
    Exit;

  Classificar(ATabuleiro, LLivres, LFecha, LSegura, LRisco);

  if Length(LFecha) > 0 then
    AAresta := EscolherEntreAsQueFecham(ATabuleiro, LFecha, Length(LSegura) > 0)
  else if Length(LSegura) > 0 then
    AAresta := Sorteia(LSegura)
  else
    AAresta := EscolherAberturaMenosPior(ATabuleiro, LRisco);

  Result := True;
end;

initialization
  // A IA sorteia entre lances equivalentes; sem isto, duas partidas seguidas
  // sairiam identicas.
  Randomize;

end.
