unit Jogo.Partida;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

{ Regras do "Pontos e Caixas" (dots and boxes), sem UI e sem rede.

  Duas classes:
  - TJogoTabuleiro: so' geometria e posse. Quem fechou cada caixa, quem
    desenhou cada aresta, quais arestas ainda estao livres.
  - TJogoPartida: as REGRAS por cima do tabuleiro — de quem e' a vez, placar,
    fim de jogo — e o unico ponto onde uma jogada e' aceita ou recusada
    (TentarJogar).

  O ponto de ter isso numa unit pura: no sample o HOSPEDEIRO e' a autoridade,
  e "ser autoridade" significa que UMA instancia de TJogoPartida decide tudo.
  A jogada do hospedeiro (clique local) e a do convidado (mensagem que chegou
  pela rede) entram pela MESMA porta, TentarJogar, com o indice do jogador
  diferente — nao ha um caminho "confiavel" e outro "da rede".

  O convidado tambem tem um TJogoPartida, mas so' como espelho: ele nunca
  chama TentarJogar, so' recebe o estado pronto (ver Jogo.Protocolo). Por isso
  os setters Definir* existem em separado — quem carrega estado vindo do fio
  nao passa pelas regras, senao estaria validando duas vezes e podendo
  divergir da autoridade.

  Convencao de indices (a mesma do modelo em Python que originou o sample):
    linhas x colunas contam CAIXAS; logo ha (linhas+1) x (colunas+1) pontos.
    aresta horizontal (r, c): liga o ponto (r, c) ao ponto (r, c+1),
      com 0 <= r <= linhas e 0 <= c < colunas.
    aresta vertical (r, c): liga o ponto (r, c) ao ponto (r+1, c),
      com 0 <= r < linhas e 0 <= c <= colunas. }

interface

uses
  SysUtils;

const
  /// Aresta livre / caixa sem dono. Nao e' 0 de proposito: 0 e' o hospedeiro.
  JOGO_SEM_DONO = -1;
  JOGO_MIN_CAIXAS = 2;
  JOGO_MAX_CAIXAS = 12;

type
  TJogoLado = (jlHorizontal, jlVertical);

  TJogoAresta = record
    Lado: TJogoLado;
    Linha: Integer;
    Coluna: Integer;
  end;

  TJogoArestas = array of TJogoAresta;

  { As caixas que tocam uma aresta: duas no meio do tabuleiro, uma na borda.
    Nunca mais que isso, dai' o array fixo em vez de lista dinamica. }
  TJogoCaixasAdjacentes = record
    Qtde: Integer;
    Linha: array[0..1] of Integer;
    Coluna: array[0..1] of Integer;
  end;

  EJogoRegra = class(Exception);

  TJogoTabuleiro = class
  private
    FLinhas: Integer;   // caixas
    FColunas: Integer;  // caixas
    // Dono de cada aresta/caixa, ou JOGO_SEM_DONO. Dimensoes em Redimensionar.
    FHoriz: array of array of Integer;
    FVert: array of array of Integer;
    FCaixas: array of array of Integer;
    function GetDonoCaixa(ALinha, AColuna: Integer): Integer;
  public
    constructor Create(ALinhas, AColunas: Integer);
    /// Troca o tamanho e zera tudo. Fora da faixa JOGO_MIN/MAX levanta.
    procedure Redimensionar(ALinhas, AColunas: Integer);
    procedure Limpar;

    /// True se os indices existem neste tabuleiro (nao diz se esta' livre).
    function ArestaExiste(const AAresta: TJogoAresta): Boolean;
    function DonoAresta(const AAresta: TJogoAresta): Integer;
    /// Escrita direta, SEM regra — para carregar estado vindo do fio.
    procedure DefinirDonoAresta(const AAresta: TJogoAresta; ADono: Integer);
    procedure DefinirDonoCaixa(ALinha, AColuna: Integer; ADono: Integer);

    /// As 4 arestas da caixa (topo, base, esquerda, direita).
    procedure ArestasDaCaixa(ALinha, AColuna: Integer;
      out ATopo, ABase, AEsq, ADir: TJogoAresta);
    /// As caixas que tem esta aresta como lado (1 na borda, 2 no meio).
    function CaixasDaAresta(const AAresta: TJogoAresta): TJogoCaixasAdjacentes;
    function LadosPreenchidos(ALinha, AColuna: Integer): Integer;
    /// Todas as arestas ainda nao jogadas.
    function ListarArestasLivres: TJogoArestas;
    /// Copia independente, para simular sequencias de jogadas sem tocar na
    /// partida real (usada pela IA em Jogo.Ia).
    function Clonar: TJogoTabuleiro;
    /// Quantas caixas a aresta fecharia/fechou (0, 1 ou 2 vizinhas).
    function FecharCaixasAdjacentes(const AAresta: TJogoAresta;
      ADono: Integer): Integer;

    function TudoPreenchido: Boolean;
    function ContarCaixasDe(ADono: Integer): Integer;

    /// Primeira aresta LIVRE a menos de ATolerancia do ponto (X, Y), em
    /// coordenadas de tela. AOrigemX/Y e' o ponto (0,0) do tabuleiro e
    /// ACelula o passo entre pontos vizinhos. False se nao ha nenhuma perto.
    function AcharArestaLivrePerto(AX, AY: Double;
      AOrigemX, AOrigemY, ACelula: Double; ATolerancia: Double;
      out AAresta: TJogoAresta): Boolean;

    property Linhas: Integer read FLinhas;
    property Colunas: Integer read FColunas;
    property DonoCaixa[ALinha, AColuna: Integer]: Integer read GetDonoCaixa;
  end;

  TJogoPartida = class
  private
    FTabuleiro: TJogoTabuleiro;
    FVez: Integer;
    FPlacar: array[0..1] of Integer;
    FTerminada: Boolean;
    // Ultima aresta aceita. Existe para a UI poder destacar a jogada que
    // acabou de acontecer — sem isso, a jogada do adversario aparece pronta no
    // tabuleiro e o jogador nao ve ONDE ela foi.
    FUltimaAresta: TJogoAresta;
    FTemUltima: Boolean;
    function GetPlacar(AJogador: Integer): Integer;
  public
    constructor Create(ALinhas, AColunas: Integer);
    destructor Destroy; override;

    /// Recomeca do zero, opcionalmente com outro tamanho. Quem comeca e'
    /// sempre o jogador 0 (o hospedeiro).
    procedure Reiniciar(ALinhas, AColunas: Integer);

    { A UNICA porta de entrada de jogada com regra. False + AMotivo quando a
      jogada nao vale; nesse caso nada no tabuleiro mudou.

      Regra classica: quem fecha caixa PONTUA e JOGA DE NOVO; quem nao fecha
      passa a vez. }
    function TentarJogar(AJogador: Integer; const AAresta: TJogoAresta;
      out AMotivo: string): Boolean;

    /// Qual foi a ultima aresta aceita. False quando ainda nao houve jogada
    /// nesta partida.
    function TryUltimaJogada(out AAresta: TJogoAresta): Boolean;

    // --- carga de estado sem regra (espelho do convidado) ---
    procedure DefinirVez(AJogador: Integer);
    procedure DefinirTerminada(AValor: Boolean);
    procedure DefinirUltimaJogada(const AAresta: TJogoAresta);
    procedure LimparUltimaJogada;
    /// Reconta o placar a partir dos donos das caixas. Chamar depois de
    /// carregar as caixas vindas do fio.
    procedure RecalcularPlacar;

    /// Indice do vencedor, ou JOGO_SEM_DONO no empate. So' faz sentido com
    /// Terminada = True.
    function Vencedor: Integer;

    property Tabuleiro: TJogoTabuleiro read FTabuleiro;
    property Vez: Integer read FVez;
    property Terminada: Boolean read FTerminada;
    property Placar[AJogador: Integer]: Integer read GetPlacar;
  end;

function JogoAresta(ALado: TJogoLado; ALinha, AColuna: Integer): TJogoAresta;
function JogoArestaIgual(const A, B: TJogoAresta): Boolean;

implementation

function JogoAresta(ALado: TJogoLado; ALinha, AColuna: Integer): TJogoAresta;
begin
  Result.Lado := ALado;
  Result.Linha := ALinha;
  Result.Coluna := AColuna;
end;

function JogoArestaIgual(const A, B: TJogoAresta): Boolean;
begin
  Result := (A.Lado = B.Lado) and (A.Linha = B.Linha) and (A.Coluna = B.Coluna);
end;

{ Distancia do ponto P ao segmento AB. Usada so' pelo hit-test do clique. }
function DistanciaPontoSegmento(APX, APY, AAX, AAY, ABX, ABY: Double): Double;
var
  LDX, LDY, LComp2, LT, LProjX, LProjY: Double;
begin
  LDX := ABX - AAX;
  LDY := ABY - AAY;
  LComp2 := LDX * LDX + LDY * LDY;
  if LComp2 = 0 then
  begin
    Result := Sqrt(Sqr(APX - AAX) + Sqr(APY - AAY));
    Exit;
  end;
  LT := ((APX - AAX) * LDX + (APY - AAY) * LDY) / LComp2;
  if LT < 0 then
    LT := 0
  else if LT > 1 then
    LT := 1;
  LProjX := AAX + LT * LDX;
  LProjY := AAY + LT * LDY;
  Result := Sqrt(Sqr(APX - LProjX) + Sqr(APY - LProjY));
end;

{ TJogoTabuleiro }

constructor TJogoTabuleiro.Create(ALinhas, AColunas: Integer);
begin
  inherited Create;
  Redimensionar(ALinhas, AColunas);
end;

procedure TJogoTabuleiro.Redimensionar(ALinhas, AColunas: Integer);
begin
  if (ALinhas < JOGO_MIN_CAIXAS) or (ALinhas > JOGO_MAX_CAIXAS) or
     (AColunas < JOGO_MIN_CAIXAS) or (AColunas > JOGO_MAX_CAIXAS) then
    raise EJogoRegra.CreateFmt('tamanho de tabuleiro invalido: %dx%d',
      [ALinhas, AColunas]);

  FLinhas := ALinhas;
  FColunas := AColunas;
  // Horizontais: uma linha a mais que caixas; verticais: uma coluna a mais.
  SetLength(FHoriz, FLinhas + 1, FColunas);
  SetLength(FVert, FLinhas, FColunas + 1);
  SetLength(FCaixas, FLinhas, FColunas);
  Limpar;
end;

procedure TJogoTabuleiro.Limpar;
var
  LR, LC: Integer;
begin
  for LR := 0 to FLinhas do
    for LC := 0 to FColunas - 1 do
      FHoriz[LR][LC] := JOGO_SEM_DONO;
  for LR := 0 to FLinhas - 1 do
    for LC := 0 to FColunas do
      FVert[LR][LC] := JOGO_SEM_DONO;
  for LR := 0 to FLinhas - 1 do
    for LC := 0 to FColunas - 1 do
      FCaixas[LR][LC] := JOGO_SEM_DONO;
end;

function TJogoTabuleiro.ArestaExiste(const AAresta: TJogoAresta): Boolean;
begin
  if AAresta.Lado = jlHorizontal then
    Result := (AAresta.Linha >= 0) and (AAresta.Linha <= FLinhas) and
              (AAresta.Coluna >= 0) and (AAresta.Coluna < FColunas)
  else
    Result := (AAresta.Linha >= 0) and (AAresta.Linha < FLinhas) and
              (AAresta.Coluna >= 0) and (AAresta.Coluna <= FColunas);
end;

function TJogoTabuleiro.DonoAresta(const AAresta: TJogoAresta): Integer;
begin
  if not ArestaExiste(AAresta) then
  begin
    Result := JOGO_SEM_DONO;
    Exit;
  end;
  if AAresta.Lado = jlHorizontal then
    Result := FHoriz[AAresta.Linha][AAresta.Coluna]
  else
    Result := FVert[AAresta.Linha][AAresta.Coluna];
end;

procedure TJogoTabuleiro.DefinirDonoAresta(const AAresta: TJogoAresta;
  ADono: Integer);
begin
  if not ArestaExiste(AAresta) then
    raise EJogoRegra.Create('aresta fora do tabuleiro');
  if AAresta.Lado = jlHorizontal then
    FHoriz[AAresta.Linha][AAresta.Coluna] := ADono
  else
    FVert[AAresta.Linha][AAresta.Coluna] := ADono;
end;

function TJogoTabuleiro.GetDonoCaixa(ALinha, AColuna: Integer): Integer;
begin
  if (ALinha < 0) or (ALinha >= FLinhas) or
     (AColuna < 0) or (AColuna >= FColunas) then
    Result := JOGO_SEM_DONO
  else
    Result := FCaixas[ALinha][AColuna];
end;

procedure TJogoTabuleiro.DefinirDonoCaixa(ALinha, AColuna: Integer;
  ADono: Integer);
begin
  if (ALinha < 0) or (ALinha >= FLinhas) or
     (AColuna < 0) or (AColuna >= FColunas) then
    raise EJogoRegra.Create('caixa fora do tabuleiro');
  FCaixas[ALinha][AColuna] := ADono;
end;

procedure TJogoTabuleiro.ArestasDaCaixa(ALinha, AColuna: Integer;
  out ATopo, ABase, AEsq, ADir: TJogoAresta);
begin
  ATopo := JogoAresta(jlHorizontal, ALinha, AColuna);
  ABase := JogoAresta(jlHorizontal, ALinha + 1, AColuna);
  AEsq := JogoAresta(jlVertical, ALinha, AColuna);
  ADir := JogoAresta(jlVertical, ALinha, AColuna + 1);
end;

function TJogoTabuleiro.CaixasDaAresta(
  const AAresta: TJogoAresta): TJogoCaixasAdjacentes;

  procedure Acrescentar(ALinha, AColuna: Integer);
  begin
    Result.Linha[Result.Qtde] := ALinha;
    Result.Coluna[Result.Qtde] := AColuna;
    Inc(Result.Qtde);
  end;

begin
  Result.Qtde := 0;
  if AAresta.Lado = jlHorizontal then
  begin
    // Horizontal: a caixa de cima (se nao for a borda superior) e a de baixo.
    if AAresta.Linha - 1 >= 0 then
      Acrescentar(AAresta.Linha - 1, AAresta.Coluna);
    if AAresta.Linha < FLinhas then
      Acrescentar(AAresta.Linha, AAresta.Coluna);
  end
  else
  begin
    // Vertical: a caixa da esquerda e a da direita.
    if AAresta.Coluna - 1 >= 0 then
      Acrescentar(AAresta.Linha, AAresta.Coluna - 1);
    if AAresta.Coluna < FColunas then
      Acrescentar(AAresta.Linha, AAresta.Coluna);
  end;
end;

function TJogoTabuleiro.ListarArestasLivres: TJogoArestas;
var
  LR, LC, LQtde: Integer;
  LAresta: TJogoAresta;

  procedure Considerar;
  begin
    if DonoAresta(LAresta) = JOGO_SEM_DONO then
    begin
      Result[LQtde] := LAresta;
      Inc(LQtde);
    end;
  end;

begin
  Result := nil; // cala o falso-positivo 5093 do FPC no SetLength abaixo
  // Teto: todas as arestas do tabuleiro. Encolhe no fim.
  SetLength(Result, (FLinhas + 1) * FColunas + FLinhas * (FColunas + 1));
  LQtde := 0;
  for LR := 0 to FLinhas do
    for LC := 0 to FColunas - 1 do
    begin
      LAresta := JogoAresta(jlHorizontal, LR, LC);
      Considerar;
    end;
  for LR := 0 to FLinhas - 1 do
    for LC := 0 to FColunas do
    begin
      LAresta := JogoAresta(jlVertical, LR, LC);
      Considerar;
    end;
  SetLength(Result, LQtde);
end;

function TJogoTabuleiro.Clonar: TJogoTabuleiro;
var
  LR, LC: Integer;
begin
  Result := TJogoTabuleiro.Create(FLinhas, FColunas);
  for LR := 0 to FLinhas do
    for LC := 0 to FColunas - 1 do
      Result.FHoriz[LR][LC] := FHoriz[LR][LC];
  for LR := 0 to FLinhas - 1 do
    for LC := 0 to FColunas do
      Result.FVert[LR][LC] := FVert[LR][LC];
  for LR := 0 to FLinhas - 1 do
    for LC := 0 to FColunas - 1 do
      Result.FCaixas[LR][LC] := FCaixas[LR][LC];
end;

function TJogoTabuleiro.LadosPreenchidos(ALinha, AColuna: Integer): Integer;
var
  LTopo, LBase, LEsq, LDir: TJogoAresta;
begin
  ArestasDaCaixa(ALinha, AColuna, LTopo, LBase, LEsq, LDir);
  Result := 0;
  if DonoAresta(LTopo) <> JOGO_SEM_DONO then Inc(Result);
  if DonoAresta(LBase) <> JOGO_SEM_DONO then Inc(Result);
  if DonoAresta(LEsq) <> JOGO_SEM_DONO then Inc(Result);
  if DonoAresta(LDir) <> JOGO_SEM_DONO then Inc(Result);
end;

function TJogoTabuleiro.FecharCaixasAdjacentes(const AAresta: TJogoAresta;
  ADono: Integer): Integer;
var
  LCaixas: TJogoCaixasAdjacentes;
  LI, LR, LC: Integer;
begin
  LCaixas := CaixasDaAresta(AAresta);
  Result := 0;
  for LI := 0 to LCaixas.Qtde - 1 do
  begin
    LR := LCaixas.Linha[LI];
    LC := LCaixas.Coluna[LI];
    if (FCaixas[LR][LC] = JOGO_SEM_DONO) and (LadosPreenchidos(LR, LC) = 4) then
    begin
      FCaixas[LR][LC] := ADono;
      Inc(Result);
    end;
  end;
end;

function TJogoTabuleiro.TudoPreenchido: Boolean;
var
  LR, LC: Integer;
begin
  for LR := 0 to FLinhas - 1 do
    for LC := 0 to FColunas - 1 do
      if FCaixas[LR][LC] = JOGO_SEM_DONO then
      begin
        Result := False;
        Exit;
      end;
  Result := True;
end;

function TJogoTabuleiro.ContarCaixasDe(ADono: Integer): Integer;
var
  LR, LC: Integer;
begin
  Result := 0;
  for LR := 0 to FLinhas - 1 do
    for LC := 0 to FColunas - 1 do
      if FCaixas[LR][LC] = ADono then
        Inc(Result);
end;

function TJogoTabuleiro.AcharArestaLivrePerto(AX, AY: Double;
  AOrigemX, AOrigemY, ACelula: Double; ATolerancia: Double;
  out AAresta: TJogoAresta): Boolean;
var
  LR, LC: Integer;
  LCand: TJogoAresta;
  LX1, LY1, LX2, LY2, LDist, LMelhor: Double;

  procedure Avaliar;
  begin
    if DonoAresta(LCand) <> JOGO_SEM_DONO then
      Exit;
    if LCand.Lado = jlHorizontal then
    begin
      LX1 := AOrigemX + LCand.Coluna * ACelula;
      LY1 := AOrigemY + LCand.Linha * ACelula;
      LX2 := LX1 + ACelula;
      LY2 := LY1;
    end
    else
    begin
      LX1 := AOrigemX + LCand.Coluna * ACelula;
      LY1 := AOrigemY + LCand.Linha * ACelula;
      LX2 := LX1;
      LY2 := LY1 + ACelula;
    end;
    LDist := DistanciaPontoSegmento(AX, AY, LX1, LY1, LX2, LY2);
    if LDist < LMelhor then
    begin
      LMelhor := LDist;
      AAresta := LCand;
      Result := True;
    end;
  end;

begin
  Result := False;
  LMelhor := ATolerancia;
  for LR := 0 to FLinhas do
    for LC := 0 to FColunas - 1 do
    begin
      LCand := JogoAresta(jlHorizontal, LR, LC);
      Avaliar;
    end;
  for LR := 0 to FLinhas - 1 do
    for LC := 0 to FColunas do
    begin
      LCand := JogoAresta(jlVertical, LR, LC);
      Avaliar;
    end;
end;

{ TJogoPartida }

constructor TJogoPartida.Create(ALinhas, AColunas: Integer);
begin
  inherited Create;
  FTabuleiro := TJogoTabuleiro.Create(ALinhas, AColunas);
  FVez := 0;
  FPlacar[0] := 0;
  FPlacar[1] := 0;
  FTerminada := False;
  FTemUltima := False;
end;

destructor TJogoPartida.Destroy;
begin
  FTabuleiro.Free;
  inherited Destroy;
end;

procedure TJogoPartida.Reiniciar(ALinhas, AColunas: Integer);
begin
  FTabuleiro.Redimensionar(ALinhas, AColunas);
  FVez := 0;
  FPlacar[0] := 0;
  FPlacar[1] := 0;
  FTerminada := False;
  FTemUltima := False;
end;

function TJogoPartida.GetPlacar(AJogador: Integer): Integer;
begin
  if (AJogador < 0) or (AJogador > 1) then
    Result := 0
  else
    Result := FPlacar[AJogador];
end;

function TJogoPartida.TentarJogar(AJogador: Integer;
  const AAresta: TJogoAresta; out AMotivo: string): Boolean;
var
  LFechadas: Integer;
begin
  Result := False;
  AMotivo := '';

  if FTerminada then
  begin
    AMotivo := 'a partida ja terminou';
    Exit;
  end;
  if (AJogador < 0) or (AJogador > 1) then
  begin
    AMotivo := 'jogador desconhecido';
    Exit;
  end;
  if AJogador <> FVez then
  begin
    AMotivo := 'nao e a sua vez';
    Exit;
  end;
  if not FTabuleiro.ArestaExiste(AAresta) then
  begin
    AMotivo := 'aresta fora do tabuleiro';
    Exit;
  end;
  if FTabuleiro.DonoAresta(AAresta) <> JOGO_SEM_DONO then
  begin
    AMotivo := 'essa aresta ja foi jogada';
    Exit;
  end;

  FTabuleiro.DefinirDonoAresta(AAresta, AJogador);
  FUltimaAresta := AAresta;
  FTemUltima := True;
  LFechadas := FTabuleiro.FecharCaixasAdjacentes(AAresta, AJogador);
  Inc(FPlacar[AJogador], LFechadas);

  // Fechou caixa: pontua e joga de novo. Nao fechou: passa a vez.
  if LFechadas = 0 then
    FVez := 1 - FVez;

  // Vale checar sempre, e nao so' quando LFechadas > 0: a checagem custa um
  // varredura de tabuleiro e nao depende de raciocinio sobre qual jogada pode
  // ou nao ser a ultima.
  if FTabuleiro.TudoPreenchido then
    FTerminada := True;

  Result := True;
end;

function TJogoPartida.TryUltimaJogada(out AAresta: TJogoAresta): Boolean;
begin
  Result := FTemUltima;
  if Result then
    AAresta := FUltimaAresta;
end;

procedure TJogoPartida.DefinirUltimaJogada(const AAresta: TJogoAresta);
begin
  FUltimaAresta := AAresta;
  FTemUltima := True;
end;

procedure TJogoPartida.LimparUltimaJogada;
begin
  FTemUltima := False;
end;

procedure TJogoPartida.DefinirVez(AJogador: Integer);
begin
  if (AJogador >= 0) and (AJogador <= 1) then
    FVez := AJogador;
end;

procedure TJogoPartida.DefinirTerminada(AValor: Boolean);
begin
  FTerminada := AValor;
end;

procedure TJogoPartida.RecalcularPlacar;
begin
  FPlacar[0] := FTabuleiro.ContarCaixasDe(0);
  FPlacar[1] := FTabuleiro.ContarCaixasDe(1);
end;

function TJogoPartida.Vencedor: Integer;
begin
  if FPlacar[0] = FPlacar[1] then
    Result := JOGO_SEM_DONO
  else if FPlacar[0] > FPlacar[1] then
    Result := 0
  else
    Result := 1;
end;

end.
