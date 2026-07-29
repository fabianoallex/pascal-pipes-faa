unit Pong.Partida;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

{ Regras e fisica do Ping Pong. Unit PURA: nao conhece a biblioteca de pipes,
  nem a UI. Quem serializa e' Pong.Protocolo; quem desenha e' uPongMain.

  A DIFERENCA PARA O PontosECaixas, e a razao de este sample existir: la' o
  mundo so' muda quando alguem clica, aqui ele anda sozinho. Isso muda tres
  coisas de projeto:

  1. MUNDO LOGICO EM UNIDADES PROPRIAS, nao em pixels. As duas janelas podem
     ter tamanhos diferentes; se a fisica fosse em pixels, cada lado simularia
     um jogo diferente. A conversao para pixel acontece so' na hora de pintar.

  2. PASSO FIXO (PONG_TICK_MS). Avancar() sempre integra o MESMO dt, e quem
     chama e' que acumula o tempo real e da' quantos passos couberem (ver
     tmrJogoTimer). Integrar "o tempo que passou desde o quadro anterior"
     deixaria a bola mais rapida numa maquina com timer irregular — e o TTimer
     do Windows tem resolucao de ~15ms com jitter de sobra para isso aparecer.

  3. AUTORIDADE EXPLICITA (AEhAutoridade no construtor). Os DOIS lados rodam
     esta mesma fisica: o hospedeiro porque e' a verdade, o convidado porque
     precisa PREVER o movimento entre um snapshot e o proximo (a 30 snapshots
     por segundo, sem previsao a bola andaria aos saltos). Mas so' a autoridade
     DECIDE: quem so' preve nao pontua e nao saca — ao ver a bola sair do campo
     ele apenas para, e espera o ESTADO que diz o que aconteceu de verdade.
     Sem esse corte, um erro de previsao de meio quadro viraria um ponto que a
     outra tela nao marcou. }

interface

const
  // --- mundo logico ---
  PONG_MUNDO_LARGURA = 1000.0;
  PONG_MUNDO_ALTURA  = 600.0;

  // --- passo de simulacao ---
  PONG_TICK_MS = 16;         // ~62 passos por segundo
  PONG_DT      = 0.016;      // o mesmo, em segundos (constante, ver item 2)

  // --- raquetes ---
  PONG_RAQUETE_ALTURA     = 110.0;
  PONG_RAQUETE_LARGURA    = 14.0;
  PONG_RAQUETE_MARGEM     = 30.0;   // distancia da parede lateral
  PONG_RAQUETE_VELOCIDADE = 660.0;  // unidades por segundo

  // --- bola ---
  PONG_BOLA_RAIO           = 9.0;
  PONG_BOLA_VELOCIDADE     = 480.0;
  PONG_BOLA_VELOCIDADE_MAX = 900.0;
  // Cada rebatida acelera: e' o que faz o ponto ter fim. Do saque ao teto sao
  // ~10 rebatidas, que e' o tamanho de rally que ainda da' para acompanhar.
  //
  // Nao adianta esperar que a bola "corra mais que a raquete" para encerrar o
  // ponto: mesmo a 900 u/s ela leva ~1,1s para atravessar o campo, e nesse
  // tempo a raquete anda 730 unidades — mais que a altura util do campo. Uma
  // raquete que SAIBA para onde ir sempre chega. Quem fecha o ponto contra o
  // computador e' o horizonte de reacao dele (ver Pong.Ia.pas), nao a
  // velocidade.
  PONG_REBATIDA_ACELERACAO = 1.07;
  PONG_ANGULO_MAX          = 1.0472;  // 60 graus, em radianos
  PONG_ANGULO_SAQUE        = 0.5236;  // 30 graus

  // Planos verticais onde a bola encosta em cada raquete (centro da bola).
  PONG_PLANO_RAQUETE0 = PONG_RAQUETE_MARGEM + PONG_RAQUETE_LARGURA +
                        PONG_BOLA_RAIO;
  PONG_PLANO_RAQUETE1 = PONG_MUNDO_LARGURA - PONG_RAQUETE_MARGEM -
                        PONG_RAQUETE_LARGURA - PONG_BOLA_RAIO;

  // --- partida ---
  PONG_PONTOS_PARA_VENCER = 7;
  PONG_PAUSA_SAQUE_MS     = 1100;

  PONG_SEM_JOGADOR = -1;

type
  TPongFase = (
    pfAguardando,  // falta o segundo jogador: a bola fica parada no centro
    pfServindo,    // contagem regressiva antes do saque
    pfJogando,
    pfTerminada
  );

  { Fotografia completa do jogo. E' o que trafega no fio (ver Pong.Protocolo) e
    o que a IA le (ver Pong.Ia) — nenhum dos dois precisa da classe. }
  TPongEstado = record
    Tick: Int64;
    Fase: TPongFase;
    EsperaMs: Integer;
    BolaX, BolaY: Double;
    VelX, VelY: Double;
    RaqueteY: array[0..1] of Double;
    // A DIRECAO de cada raquete (-1/0/+1) vai junto, e nao e' redundante com a
    // posicao: sem ela o espelho preveria as duas raquetes PARADAS entre um
    // snapshot e o proximo. Contra um humano — que segura a tecla por centenas
    // de milissegundos — a diferenca e' entre uma raquete que desliza e uma que
    // pula de correcao em correcao.
    //
    // Medido a 31 snapshots/s: COM o campo, a previsao da bola no espelho fica
    // a 0,0 unidade da autoridade; SEM ele, chega a 12. O erro nao aparece na
    // raquete, aparece na BOLA — uma raquete adivinhada um pouco fora rebate
    // num angulo um pouco diferente, e a partir dai as duas telas contam
    // historias diferentes ate' o proximo snapshot.
    Entrada: array[0..1] of Integer;
    Placar: array[0..1] of Integer;
  end;

  TPongPartida = class
  private
    FEhAutoridade: Boolean;
    FTick: Int64;
    FFase: TPongFase;
    FEsperaMs: Integer;
    FSaquePara: Integer;
    FBolaX, FBolaY: Double;
    FVelX, FVelY: Double;
    FRaqueteY: array[0..1] of Double;
    FEntrada: array[0..1] of Integer;
    FPlacar: array[0..1] of Integer;

    procedure CentralizarBola;
    procedure MoverRaquetes;
    procedure MoverBola;
    /// Rebatida com travessia de plano (ver comentario no corpo).
    function TentarRebater(AJogador: Integer; AAntX, AAntY, APlano: Double): Boolean;
    procedure Lancar;
    procedure Gol(AJogador: Integer);
    function GetPlacar(AIndice: Integer): Integer;
    function GetRaqueteY(AIndice: Integer): Double;
  public
    /// AEhAutoridade = False cria um ESPELHO: ele simula (para prever entre
    /// snapshots) mas nao pontua nem saca. Ver o item 3 do cabecalho.
    constructor Create(AEhAutoridade: Boolean);

    /// Zera placar e posicoes. NAO zera o Tick de proposito: o tick e' um
    /// numero de sequencia da SESSAO, nao da partida, e quem esta' do outro
    /// lado o usa para saber se um ESTADO e' mais novo que o anterior. Zerar
    /// aqui faria o convidado descartar tudo depois de um "Nova partida".
    procedure Reiniciar;

    /// Um passo de PONG_DT. Chamado pelos DOIS lados.
    procedure Avancar;

    procedure DefinirEntrada(AJogador, ADirecao: Integer);
    /// Estaciona o jogo (falta jogador). Preserva o placar.
    procedure Aguardar;
    /// Arma o saque em direcao a AParaJogador.
    procedure Servir(AParaJogador: Integer);
    /// Volta de um pfAguardando mantendo de quem era o saque.
    procedure Retomar;

    procedure Capturar(out AEstado: TPongEstado);
    /// Sobrescreve TUDO com o que a autoridade mandou. Espelho nao valida:
    /// validar aqui seria ter uma segunda opiniao sobre a verdade.
    procedure Aplicar(const AEstado: TPongEstado);

    function Vencedor: Integer;

    property Tick: Int64 read FTick;
    property Fase: TPongFase read FFase;
    property EsperaMs: Integer read FEsperaMs;
    property BolaX: Double read FBolaX;
    property BolaY: Double read FBolaY;
    property Placar[AIndice: Integer]: Integer read GetPlacar;
    property RaqueteY[AIndice: Integer]: Double read GetRaqueteY;
  end;

implementation

function AbsD(AValor: Double): Double;
begin
  if AValor < 0 then
    Result := -AValor
  else
    Result := AValor;
end;

function Limitar(AValor, AMin, AMax: Double): Double;
begin
  Result := AValor;
  if Result < AMin then
    Result := AMin
  else if Result > AMax then
    Result := AMax;
end;

{ TPongPartida }

constructor TPongPartida.Create(AEhAutoridade: Boolean);
begin
  inherited Create;
  FEhAutoridade := AEhAutoridade;
  FTick := 0;
  Reiniciar;
end;

procedure TPongPartida.Reiniciar;
begin
  FPlacar[0] := 0;
  FPlacar[1] := 0;
  FRaqueteY[0] := PONG_MUNDO_ALTURA / 2;
  FRaqueteY[1] := PONG_MUNDO_ALTURA / 2;
  FEntrada[0] := 0;
  FEntrada[1] := 0;
  FSaquePara := 1;
  FFase := pfAguardando;
  FEsperaMs := 0;
  CentralizarBola;
end;

procedure TPongPartida.CentralizarBola;
begin
  FBolaX := PONG_MUNDO_LARGURA / 2;
  FBolaY := PONG_MUNDO_ALTURA / 2;
  FVelX := 0;
  FVelY := 0;
end;

procedure TPongPartida.DefinirEntrada(AJogador, ADirecao: Integer);
begin
  if (AJogador < 0) or (AJogador > 1) then
    Exit;
  if ADirecao > 0 then
    FEntrada[AJogador] := 1
  else if ADirecao < 0 then
    FEntrada[AJogador] := -1
  else
    FEntrada[AJogador] := 0;
end;

procedure TPongPartida.Aguardar;
begin
  if FFase = pfTerminada then
    Exit;
  FFase := pfAguardando;
  FEsperaMs := 0;
  CentralizarBola;
end;

procedure TPongPartida.Servir(AParaJogador: Integer);
begin
  FSaquePara := AParaJogador;
  FFase := pfServindo;
  FEsperaMs := PONG_PAUSA_SAQUE_MS;
  CentralizarBola;
end;

procedure TPongPartida.Retomar;
begin
  if FFase <> pfAguardando then
    Exit;
  Servir(FSaquePara);
end;

procedure TPongPartida.Avancar;
begin
  Inc(FTick);
  // As raquetes andam em TODA fase — inclusive esperando o convidado. E' o que
  // faz a tela parecer viva enquanto ninguem entrou.
  MoverRaquetes;

  case FFase of
    pfServindo:
      begin
        Dec(FEsperaMs, PONG_TICK_MS);
        if FEsperaMs <= 0 then
        begin
          FEsperaMs := 0;
          // So' a autoridade sorteia o angulo do saque. O espelho fica em
          // pfServindo com a bola parada ate' o ESTADO trazer a velocidade
          // real; sorteassem os dois, cada tela veria uma bola diferente.
          if FEhAutoridade then
            Lancar;
        end;
      end;
    pfJogando:
      MoverBola;
  end;
end;

procedure TPongPartida.MoverRaquetes;
var
  LIdx: Integer;
  LMeia: Double;
begin
  LMeia := PONG_RAQUETE_ALTURA / 2;
  for LIdx := 0 to 1 do
    FRaqueteY[LIdx] := Limitar(
      FRaqueteY[LIdx] + FEntrada[LIdx] * PONG_RAQUETE_VELOCIDADE * PONG_DT,
      LMeia, PONG_MUNDO_ALTURA - LMeia);
end;

procedure TPongPartida.Lancar;
var
  LAngulo, LDirecao: Double;
begin
  LAngulo := (Random - 0.5) * 2 * PONG_ANGULO_SAQUE;
  if FSaquePara = 0 then
    LDirecao := -1
  else
    LDirecao := 1;
  FVelX := LDirecao * PONG_BOLA_VELOCIDADE * Cos(LAngulo);
  FVelY := PONG_BOLA_VELOCIDADE * Sin(LAngulo);
  FFase := pfJogando;
end;

procedure TPongPartida.MoverBola;
var
  LAntX, LAntY: Double;
begin
  LAntX := FBolaX;
  LAntY := FBolaY;
  FBolaX := FBolaX + FVelX * PONG_DT;
  FBolaY := FBolaY + FVelY * PONG_DT;

  // Paredes de cima e de baixo. A checagem do sinal da velocidade evita que a
  // bola fique "colada" invertendo o sinal a cada quadro se entrar na parede.
  if (FBolaY < PONG_BOLA_RAIO) and (FVelY < 0) then
  begin
    FBolaY := PONG_BOLA_RAIO;
    FVelY := -FVelY;
  end
  else if (FBolaY > PONG_MUNDO_ALTURA - PONG_BOLA_RAIO) and (FVelY > 0) then
  begin
    FBolaY := PONG_MUNDO_ALTURA - PONG_BOLA_RAIO;
    FVelY := -FVelY;
  end;

  if FVelX < 0 then
    TentarRebater(0, LAntX, LAntY, PONG_PLANO_RAQUETE0)
  else if FVelX > 0 then
    TentarRebater(1, LAntX, LAntY, PONG_PLANO_RAQUETE1);

  if FBolaX < -PONG_BOLA_RAIO then
    Gol(1)
  else if FBolaX > PONG_MUNDO_LARGURA + PONG_BOLA_RAIO then
    Gol(0);
end;

function TPongPartida.TentarRebater(AJogador: Integer;
  AAntX, AAntY, APlano: Double): Boolean;
var
  LCruzou: Boolean;
  LFracao, LY, LOffset, LMeia, LVelocidade, LAngulo: Double;
begin
  Result := False;

  // Testar SOBREPOSICAO (bola dentro da raquete) nao serve: a 900 u/s a bola
  // anda ~14 unidades por quadro, que e' a espessura da raquete — ela passaria
  // direto num quadro em que nunca esteve "dentro". O teste e' de TRAVESSIA do
  // plano entre a posicao anterior e a atual.
  if AJogador = 0 then
    LCruzou := (AAntX >= APlano) and (FBolaX <= APlano)
  else
    LCruzou := (AAntX <= APlano) and (FBolaX >= APlano);
  if not LCruzou then
    Exit;

  // Onde a bola estava em Y no instante exato da travessia.
  if AbsD(FBolaX - AAntX) > 1E-9 then
    LFracao := (APlano - AAntX) / (FBolaX - AAntX)
  else
    LFracao := 0;
  LY := AAntY + (FBolaY - AAntY) * LFracao;

  LMeia := PONG_RAQUETE_ALTURA / 2 + PONG_BOLA_RAIO;
  LOffset := (LY - FRaqueteY[AJogador]) / LMeia;
  if AbsD(LOffset) > 1 then
    Exit; // passou por fora da raquete: e' ponto do outro lado

  // Angulo de saida pelo ponto da raquete que foi atingido — o "controle" do
  // pong classico. Bater com a ponta manda a bola para o canto.
  LAngulo := Limitar(LOffset, -1, 1) * PONG_ANGULO_MAX;
  LVelocidade := Sqrt(Sqr(FVelX) + Sqr(FVelY)) * PONG_REBATIDA_ACELERACAO;
  if LVelocidade > PONG_BOLA_VELOCIDADE_MAX then
    LVelocidade := PONG_BOLA_VELOCIDADE_MAX;

  if AJogador = 0 then
    FVelX := LVelocidade * Cos(LAngulo)
  else
    FVelX := -LVelocidade * Cos(LAngulo);
  FVelY := LVelocidade * Sin(LAngulo);

  FBolaX := APlano;
  FBolaY := LY;
  Result := True;
end;

procedure TPongPartida.Gol(AJogador: Integer);
begin
  if not FEhAutoridade then
  begin
    // Espelho: a previsao chegou ate' o fundo do campo, mas quem marca ponto e'
    // o hospedeiro. Parar a bola aqui deixa a tela estavel ate' o ESTADO
    // chegar, em vez de mostrar um placar que talvez nao exista.
    FVelX := 0;
    FVelY := 0;
    Exit;
  end;

  Inc(FPlacar[AJogador]);
  if FPlacar[AJogador] >= PONG_PONTOS_PARA_VENCER then
  begin
    FFase := pfTerminada;
    CentralizarBola;
    Exit;
  end;
  // O saque vai para quem levou o ponto.
  Servir(1 - AJogador);
end;

procedure TPongPartida.Capturar(out AEstado: TPongEstado);
var
  LIdx: Integer;
begin
  AEstado.Tick := FTick;
  AEstado.Fase := FFase;
  AEstado.EsperaMs := FEsperaMs;
  AEstado.BolaX := FBolaX;
  AEstado.BolaY := FBolaY;
  AEstado.VelX := FVelX;
  AEstado.VelY := FVelY;
  for LIdx := 0 to 1 do
  begin
    AEstado.RaqueteY[LIdx] := FRaqueteY[LIdx];
    AEstado.Entrada[LIdx] := FEntrada[LIdx];
    AEstado.Placar[LIdx] := FPlacar[LIdx];
  end;
end;

procedure TPongPartida.Aplicar(const AEstado: TPongEstado);
var
  LIdx: Integer;
begin
  FTick := AEstado.Tick;
  FFase := AEstado.Fase;
  FEsperaMs := AEstado.EsperaMs;
  FBolaX := AEstado.BolaX;
  FBolaY := AEstado.BolaY;
  FVelX := AEstado.VelX;
  FVelY := AEstado.VelY;
  for LIdx := 0 to 1 do
  begin
    FRaqueteY[LIdx] := AEstado.RaqueteY[LIdx];
    FEntrada[LIdx] := AEstado.Entrada[LIdx];
    FPlacar[LIdx] := AEstado.Placar[LIdx];
  end;
end;

function TPongPartida.Vencedor: Integer;
begin
  if FFase <> pfTerminada then
    Result := PONG_SEM_JOGADOR
  else if FPlacar[0] > FPlacar[1] then
    Result := 0
  else if FPlacar[1] > FPlacar[0] then
    Result := 1
  else
    Result := PONG_SEM_JOGADOR;
end;

function TPongPartida.GetPlacar(AIndice: Integer): Integer;
begin
  if (AIndice < 0) or (AIndice > 1) then
    Result := 0
  else
    Result := FPlacar[AIndice];
end;

function TPongPartida.GetRaqueteY(AIndice: Integer): Double;
begin
  if (AIndice < 0) or (AIndice > 1) then
    Result := PONG_MUNDO_ALTURA / 2
  else
    Result := FRaqueteY[AIndice];
end;

end.
