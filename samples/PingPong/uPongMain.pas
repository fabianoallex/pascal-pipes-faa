unit uPongMain;

{ Ping Pong para dois jogadores em rede, com UI (VCL no Delphi, LCL no Lazarus)
  a partir do MESMO fonte.

  Um jogador clica "Hospedar" e vira o servidor da partida; o outro digita o
  endereco dele, clica "Entrar" e joga junto. O transporte e' escolhido no
  combo: ptLocal (duas janelas na mesma maquina) ou ptTcp (duas maquinas).
  Setas (ou W/S) movem a raquete.

  PARA TESTAR SOZINHO nao e' preciso abrir duas janelas: marque "Computador
  ocupa a vaga do convidado" antes de Hospedar e a partida comeca na hora,
  contra a maquina. As duas marcacoes de bot valem juntas — e ai' o jogo roda
  sozinho, que e' o modo mais rapido de ver a fisica e a rede trabalhando.

  O QUE ESTE SAMPLE MOSTRA, e que o PontosECaixas nao mostra: o mundo anda
  SOZINHO. Um jogo de turno so' fala na rede quando alguem clica; aqui a bola
  se mexe 60 vezes por segundo, e isso muda cinco coisas.

  1. O RELOGIO DO JOGO NAO E' O TTimer. tmrJogo dispara "mais ou menos" a cada
     15ms — a resolucao do timer do Windows e' de ~15ms com jitter, e a janela
     minimizada ou o debugger parado abrem buracos de segundos. O que roda a
     fisica e' um ACUMULADOR: mede o tempo real decorrido e da' quantos passos
     de PONG_TICK_MS couberem. Sem isso a bola andaria mais rapido ou mais
     devagar conforme a maquina, e as duas telas divergiriam.

  2. ENTRADA VAI POR BORDA, ESTADO VEM POR NIVEL. O convidado so' manda quando
     a direcao da raquete MUDA (algumas mensagens por segundo, nao 60); o
     hospedeiro manda a fotografia inteira a cada PONG_TICKS_POR_SNAPSHOT
     passos, tenha mudado algo ou nao. Ver o cabecalho de Pong.Protocolo.pas
     para o porque de cada escolha — e por que a primeira seria um bug em UDP.

  3. O CONVIDADO PREVE. A ~31 snapshots por segundo, desenhar so' o que chegou
     daria uma bola aos saltos. Entao o espelho roda a MESMA fisica localmente
     entre um snapshot e o proximo, e cada ESTADO que chega corrige o que
     tiver divergido. E' por isso que TPongPartida existe nos dois lados — mas
     com AEhAutoridade = False no convidado: prever movimento e' uma coisa,
     decidir ponto e' outra.

  4. ATE' A PREVISAO TEM PRAZO. Se o hospedeiro sumir, o espelho continuaria
     alegremente simulando uma partida que nao existe mais. Depois de
     SEM_SINAL_MS sem ESTADO, a previsao CONGELA e a tela diz isso. Preferir
     uma tela parada e honesta a uma tela animada e errada.

  5. O BOT NAO TEM TIMER. No PontosECaixas o bot e' chamado uma vez por turno,
     com pausa proposital. Aqui ele e' chamado dentro do passo de simulacao,
     junto com a fisica, porque a raquete dele decide o tempo todo. E entra
     pela mesma porta do teclado: no convidado, a direcao que ele devolve vira
     uma mensagem ENTRADA na rede.

  Vale de novo o que o PontosECaixas ja' mostrava, e que aqui continua igual:
  servidor autoritativo, reconexao pelo token repetido no OnConnected, e as
  duas camadas de recusa (MaxClients como teto de recurso, "a partida ja tem
  dois jogadores" como regra de negocio, com motivo antes de desligar).

  THREADING: DispatchMode = pdmMainThread nos dois papeis, entao todo o estado
  do jogo e' tocado apenas na thread da UI — nao ha um unico lock neste fonte.
  A contrapartida esta' em PedirDesligamento, abaixo.

  Regras/fisica e protocolo ficam em units puras (Pong.Partida, Pong.Protocolo,
  Pong.Ia); aqui so' ha UI e rede. }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  {$IFDEF FPC}
  LCLIntf, LCLType,
  {$ELSE}
  Windows, Messages,
  {$ENDIF}
  SysUtils, Classes, Types,
  Graphics, Controls, Forms, Dialogs, StdCtrls, ExtCtrls,
  Pipes.Types, Pipes.Framing, Pipes.Server, Pipes.Client,
  Pong.Partida, Pong.Protocolo, Pong.Ia;

type
  TfrmPong = class(TForm)
    lblEndereco: TLabel;
    edtEndereco: TEdit;
    cbTransporte: TComboBox;
    lblApelido: TLabel;
    edtApelido: TEdit;
    lblDificuldade: TLabel;
    cbDificuldade: TComboBox;
    btnHospedar: TButton;
    btnEntrar: TButton;
    btnSair: TButton;
    btnNovaPartida: TButton;
    chkBotPorMim: TCheckBox;
    chkBotConvidado: TCheckBox;
    lblStatus: TLabel;
    lblAjuda: TLabel;
    pbCampo: TPaintBox;
    memoLog: TMemo;
    tmrJogo: TTimer;
    tmrDesligar: TTimer;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormKeyUp(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure btnHospedarClick(Sender: TObject);
    procedure btnEntrarClick(Sender: TObject);
    procedure btnSairClick(Sender: TObject);
    procedure btnNovaPartidaClick(Sender: TObject);
    procedure cbTransporteChange(Sender: TObject);
    procedure pbCampoPaint(Sender: TObject);
    procedure tmrJogoTimer(Sender: TObject);
    procedure tmrDesligarTimer(Sender: TObject);
  private
    FServer: TPipeServer;   // <> nil = sou o hospedeiro
    FClient: TPipeClient;   // <> nil = sou o convidado
    FPartida: TPongPartida;
    FMeuIndice: Integer;    // 0 hospedeiro, 1 convidado, PONG_SEM_JOGADOR = fora
    FToken: string;         // identidade de reconexao (convidado)
    FApelido0: string;
    FApelido1: string;
    FVagaConn: TPipeConnectionId;
    FVagaToken: string;
    FBotPorMim: Boolean;
    FBotConvidado: Boolean;
    FDificuldade: TPongDificuldade;

    // Teclado: guardo as duas teclas separadas porque a direcao resultante
    // depende das duas (segurar cima e baixo ao mesmo tempo = parado).
    FCimaPress: Boolean;
    FBaixoPress: Boolean;
    FMinhaDirecao: Integer;

    // Relogio da simulacao (ver item 1 do cabecalho).
    FRelogioMs: UInt64;
    FAcumuladorMs: Integer;
    FTicksDesdeSnapshot: Integer;

    // Convidado: quando chegou o ultimo ESTADO, e qual era o tick dele.
    FUltimoSnapshotMs: UInt64;
    FUltimoTickAplicado: Int64;
    FSemSinal: Boolean;

    // Layout do campo em pixels, recalculado a cada Paint.
    FEscala: Double;
    FOrigemX: Double;
    FOrigemY: Double;
    FMotivoDesligar: string;

    procedure Log(const ATexto: string);
    function SouHospedeiro: Boolean;
    function EstouLigado: Boolean;
    function TransporteEscolhido: TPipeTransport;
    function ApelidoOuPadrao(const APadrao: string): string;
    function NomeConvidado: string;
    /// True quando o teclado desta janela comanda alguma raquete.
    function ControloRaquete: Boolean;

    procedure LigarRelogio;
    procedure PassoDeSimulacao;
    procedure AplicarBots;
    procedure AtualizarMinhaDirecao;
    /// Porta unica da entrada local: teclado e bot passam por aqui. So' vai ao
    /// fio quando a direcao MUDA (ver item 2 do cabecalho).
    procedure DefinirMinhaDirecao(ADirecao: Integer);

    procedure CalcularLayout;
    function PX(AMundoX: Double): Integer;
    function PY(AMundoY: Double): Integer;
    function PE(AMundo: Double): Integer;

    procedure AtualizarUi;
    procedure Desligar;
    /// Agenda o desligamento para FORA do callback (ver comentario no corpo).
    procedure PedirDesligamento(const AMotivo: string);
    procedure EnviarEstado;
    /// Hospedeiro: liga/pausa a partida conforme haja ou nao um segundo jogador.
    procedure AvaliarPresenca;

    // --- handlers da lib (pdmMainThread: rodam na thread da UI) ---
    procedure SrvMessage(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure SrvConnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure SrvDisconnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure CliMessage(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure CliConnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure CliDisconnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure AnyError(Sender: TObject; AConnId: TPipeConnectionId;
      const AError: string);

    // --- tratamento das mensagens no hospedeiro ---
    procedure TratarOi(AConnId: TPipeConnectionId; const ALinha: string);
    procedure TratarEntrada(AConnId: TPipeConnectionId; const ALinha: string);
    procedure EnviarPara(AConnId: TPipeConnectionId; const ALinha: string);
  end;

var
  frmPong: TfrmPong;

implementation

{$IFDEF FPC}
  {$R *.lfm}
{$ELSE}
  {$R *.dfm}
{$ENDIF}

const
  ENDERECO_LOCAL_PADRAO = 'pipes_faa_pong';
  ENDERECO_TCP_PADRAO = '127.0.0.1:5100';

  // Um snapshot a cada 2 passos: ~31 por segundo. Cada linha de ESTADO tem
  // ~80 bytes de texto, mais 20 do cabecalho NPF1 do framing — algo como
  // 3,1 KB/s por cliente. A banda nunca e' o gargalo num jogo desses.
  //
  // A taxa nao esta' aqui por causa da suavidade da animacao (a previsao ja'
  // resolve isso): esta' por causa do ERRO ACUMULADO na previsao. Medindo o
  // espelho contra a autoridade numa partida de 3 minutos:
  //
  //     31 snapshots/s  ->  erro maximo da bola  0,0 unidade
  //      6 snapshots/s  ->  erro maximo da bola   ~60 unidades
  //
  // Nao e' linear porque o erro so' explode nas REBATIDAS: enquanto a bola
  // viaja em linha reta as duas simulacoes concordam exatamente, mas se um
  // quique acontece no meio de um intervalo longo, ele acontece contra uma
  // raquete prevista fora do lugar e o angulo de saida ja' nasce errado. O
  // intervalo tem que ser curto o bastante para que uma correcao caia entre
  // duas rebatidas — nao para que a bola pareca lisa.
  PONG_TICKS_POR_SNAPSHOT = 2;

  // Tempo sem ESTADO depois do qual o espelho para de prever (item 4).
  SEM_SINAL_MS = 1500;

  // Teto de passos por disparo do timer. Depois de uma pausa longa (janela
  // minimizada, breakpoint), o acumulado pode valer centenas de passos: dar
  // todos travaria a UI para "recuperar" um jogo que ninguem viu. Melhor
  // perder o tempo parado do que congelar a janela.
  MAX_PASSOS_POR_QUADRO = 5;

{ Paleta escura, no espirito do PontosECaixas. TColor e' BGR nas duas RTLs,
  entao este helper evita depender de RGB() (Windows) ou RGBToColor() (LCL). }
function Cor(R, G, B: Byte): TColor;
begin
  Result := TColor(R or (G shl 8) or (B shl 16));
end;

function CorDoJogador(AIndice: Integer): TColor;
begin
  if AIndice = 0 then
    Result := Cor(57, 135, 229)   // azul
  else
    Result := Cor(217, 89, 38);   // laranja
end;

{ TfrmPong }

procedure TfrmPong.FormCreate(Sender: TObject);
begin
  DoubleBuffered := True; // o campo inteiro e' redesenhado ~60x por segundo
  Randomize;              // o angulo do saque sai daqui (so' na autoridade)
  KeyPreview := True;     // as setas tem que chegar aqui, nao ao botao com foco

  // Autoridade: so' quem hospeda vira True (ver btnHospedarClick). Comeco como
  // espelho porque, antes de escolher o papel, nao ha partida a decidir.
  FPartida := TPongPartida.Create(False);
  FMeuIndice := PONG_SEM_JOGADOR;
  FToken := PongNovoToken;
  FApelido0 := 'Hospedeiro';
  FApelido1 := 'Convidado';
  FVagaConn := PIPE_INVALID_CONNECTION;
  FMotivoDesligar := 'parado';
  FDificuldade := pdMedio;
  cbTransporte.ItemIndex := 0;
  cbDificuldade.ItemIndex := 1;
  edtEndereco.Text := ENDERECO_LOCAL_PADRAO;

  Log('Ping Pong em rede.');
  Log('Um lado clica "Hospedar"; o outro digita o endereco e clica "Entrar".');
  Log('Para jogar sozinho: marque "Computador ocupa a vaga do convidado" e');
  Log('clique Hospedar - nao precisa de segunda janela.');
  Log('Setas cima/baixo (ou W/S) movem a sua raquete.');
  AtualizarUi;
end;

procedure TfrmPong.FormDestroy(Sender: TObject);
begin
  // Eventos pdmMainThread ainda na fila viram no-op depois daqui (objeto-guarda
  // da lib): fechar a janela no meio da partida e' seguro.
  FreeAndNil(FClient);
  FreeAndNil(FServer);
  FreeAndNil(FPartida);
end;

procedure TfrmPong.Log(const ATexto: string);
begin
  memoLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + ATexto);
end;

function TfrmPong.SouHospedeiro: Boolean;
begin
  Result := FServer <> nil;
end;

function TfrmPong.EstouLigado: Boolean;
begin
  Result := (FServer <> nil) or (FClient <> nil);
end;

function TfrmPong.TransporteEscolhido: TPipeTransport;
begin
  if cbTransporte.ItemIndex = 1 then
    Result := ptTcp
  else
    Result := ptLocal;
end;

function TfrmPong.ApelidoOuPadrao(const APadrao: string): string;
begin
  Result := Trim(edtApelido.Text);
  if Result = '' then
    Result := APadrao;
end;

function TfrmPong.NomeConvidado: string;
begin
  if not SouHospedeiro then
    Result := FApelido1
  else if FBotConvidado then
    Result := FApelido1
  else if FVagaToken = '' then
    Result := '(aguardando)'
  else if FVagaConn = PIPE_INVALID_CONNECTION then
    Result := FApelido1 + ' (caiu)'
  else
    Result := FApelido1;
end;

function TfrmPong.ControloRaquete: Boolean;
begin
  // FBotPorMim exclui o teclado de proposito: com os dois ativos, o jogador e
  // a IA disputariam a mesma raquete a cada passo.
  Result := EstouLigado and (FMeuIndice >= 0) and (not FBotPorMim);
end;

{ --- teclado --- }

procedure TfrmPong.FormKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  // Nao roubar as setas de quem esta' digitando num campo (ou navegando um
  // combo): KeyPreview ve TUDO antes do controle com foco.
  if (ActiveControl is TCustomEdit) or (ActiveControl is TCustomComboBox) then
    Exit;
  if not ControloRaquete then
    Exit;

  case Key of
    VK_UP, Ord('W'): FCimaPress := True;
    VK_DOWN, Ord('S'): FBaixoPress := True;
  else
    Exit;
  end;
  Key := 0;
  AtualizarMinhaDirecao;
end;

procedure TfrmPong.FormKeyUp(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  // O KeyUp NAO checa ControloRaquete: se a tecla foi solta depois de o jogo
  // parar (ou de o bot assumir), a marca precisa cair de qualquer jeito —
  // senao a raquete voltaria correndo sozinha na proxima partida.
  case Key of
    VK_UP, Ord('W'): FCimaPress := False;
    VK_DOWN, Ord('S'): FBaixoPress := False;
  else
    Exit;
  end;
  Key := 0;
  AtualizarMinhaDirecao;
end;

procedure TfrmPong.AtualizarMinhaDirecao;
var
  LDirecao: Integer;
begin
  if FBotPorMim then
    Exit; // a raquete e' do bot nesta sessao
  LDirecao := 0;
  if FCimaPress then
    Dec(LDirecao);
  if FBaixoPress then
    Inc(LDirecao);
  DefinirMinhaDirecao(LDirecao);
end;

procedure TfrmPong.DefinirMinhaDirecao(ADirecao: Integer);
begin
  if ADirecao = FMinhaDirecao then
    Exit; // por BORDA: nada mudou, nada vai ao fio
  FMinhaDirecao := ADirecao;
  if FMeuIndice < 0 then
    Exit;

  // Aplico local SEMPRE, inclusive no convidado: e' a previsao que faz a
  // raquete responder na hora em vez de esperar o proximo ESTADO. A autoridade
  // vai confirmar (ou corrigir) a posicao no snapshot seguinte.
  FPartida.DefinirEntrada(FMeuIndice, ADirecao);

  if SouHospedeiro then
    Exit;
  try
    FClient.SendText(PongEncodeEntrada(ADirecao));
  except
    on E: EPipeError do
      Log('falha ao enviar a entrada: ' + E.Message);
  end;
end;

{ --- simulacao --- }

procedure TfrmPong.LigarRelogio;
begin
  FRelogioMs := GetTickCount64;
  FAcumuladorMs := 0;
  FTicksDesdeSnapshot := 0;
  tmrJogo.Enabled := True;
end;

procedure TfrmPong.tmrJogoTimer(Sender: TObject);
var
  LAgora: UInt64;
  LDelta, LPassos: Integer;
begin
  LAgora := GetTickCount64;
  LDelta := Integer(LAgora - FRelogioMs);
  FRelogioMs := LAgora;
  if LDelta < 0 then
    LDelta := 0;

  Inc(FAcumuladorMs, LDelta);
  LPassos := 0;
  while (FAcumuladorMs >= PONG_TICK_MS) and (LPassos < MAX_PASSOS_POR_QUADRO) do
  begin
    Dec(FAcumuladorMs, PONG_TICK_MS);
    Inc(LPassos);
    PassoDeSimulacao;
  end;
  // Sobra grande = houve uma pausa longa. Descarta em vez de correr atras.
  if FAcumuladorMs > PONG_TICK_MS * MAX_PASSOS_POR_QUADRO then
    FAcumuladorMs := 0;

  pbCampo.Invalidate;
end;

procedure TfrmPong.PassoDeSimulacao;
begin
  if not SouHospedeiro then
  begin
    // Espelho sem sinal: congela em vez de simular uma partida que talvez nem
    // exista mais do outro lado (item 4 do cabecalho).
    FSemSinal := (FUltimoSnapshotMs > 0) and
      (GetTickCount64 - FUltimoSnapshotMs > SEM_SINAL_MS);
    if FSemSinal or (FUltimoSnapshotMs = 0) then
      Exit;
  end;

  AplicarBots;
  FPartida.Avancar;

  if not SouHospedeiro then
    Exit;

  Inc(FTicksDesdeSnapshot);
  if FTicksDesdeSnapshot >= PONG_TICKS_POR_SNAPSHOT then
  begin
    FTicksDesdeSnapshot := 0;
    EnviarEstado;
  end;
end;

procedure TfrmPong.AplicarBots;
var
  LEstado: TPongEstado;
begin
  if not (FBotPorMim or FBotConvidado) then
    Exit;

  FPartida.Capturar(LEstado);

  if SouHospedeiro then
  begin
    // Hospedeiro e' sempre o jogador 0; o bot da vaga do convidado joga o 1.
    if FBotPorMim then
      FPartida.DefinirEntrada(0, PongIaDirecao(LEstado, 0, FDificuldade));
    if FBotConvidado then
      FPartida.DefinirEntrada(1, PongIaDirecao(LEstado, 1, FDificuldade));
    Exit;
  end;

  // Convidado: a direcao escolhida entra pela MESMA porta do teclado, entao
  // vira ENTRADA na rede quando muda — e passa pela validacao do hospedeiro
  // como a de qualquer humano.
  if FBotPorMim and (FMeuIndice >= 0) then
    DefinirMinhaDirecao(PongIaDirecao(LEstado, FMeuIndice, FDificuldade));
end;

{ --- papel de hospedeiro (servidor, e autoridade da partida) --- }

procedure TfrmPong.btnHospedarClick(Sender: TObject);
begin
  FreeAndNil(FPartida);
  FPartida := TPongPartida.Create(True); // eu sou a verdade
  FMeuIndice := 0;
  FBotPorMim := chkBotPorMim.Checked;
  FBotConvidado := chkBotConvidado.Checked;
  FDificuldade := PongDificuldadeDeIndice(cbDificuldade.ItemIndex);
  FApelido0 := ApelidoOuPadrao('Hospedeiro');
  if FBotPorMim then
    FApelido0 := FApelido0 + ' (computador)';
  if FBotConvidado then
    FApelido1 := 'Computador'
  else
    FApelido1 := 'Convidado';
  FVagaConn := PIPE_INVALID_CONNECTION;
  FVagaToken := '';
  FMinhaDirecao := 0;
  FCimaPress := False;
  FBaixoPress := False;

  FServer := TPipeServer.Create(Trim(edtEndereco.Text), TransporteEscolhido);
  FServer.DispatchMode := pdmMainThread;
  // Teto de RECURSO, nao regra do jogo: a vaga de jogador e' UMA, e quem
  // decide isso e' o tratamento do OI. A folga de uma conexao existe para que
  // um terceiro interessado consiga ser ACEITO pelo transporte e receber o
  // "RECUSADO|..." explicando o motivo.
  FServer.MaxClients := 2;
  FServer.OnMessage := SrvMessage;
  FServer.OnClientConnected := SrvConnected;
  FServer.OnClientDisconnected := SrvDisconnected;
  FServer.OnError := AnyError;
  try
    FServer.Listen;
  except
    FreeAndNil(FServer);
    FMeuIndice := PONG_SEM_JOGADOR;
    raise;
  end;

  AvaliarPresenca;
  LigarRelogio;
  if FBotConvidado then
    Log('hospedando em "' + FServer.Address +
      '" - a vaga do convidado esta com o computador.')
  else
    Log('hospedando em "' + FServer.Address + '" - aguardando convidado.');
  AtualizarUi;
end;

procedure TfrmPong.AvaliarPresenca;
begin
  if not SouHospedeiro then
    Exit;
  if FBotConvidado or (FVagaConn <> PIPE_INVALID_CONNECTION) then
    // Retomar so' age se estava em pfAguardando: uma reconexao no meio de um
    // ponto nao pode reiniciar o saque.
    FPartida.Retomar
  else
    // Sem segundo jogador a bola estaciona. O placar fica: quem voltar retoma
    // a partida onde ela parou.
    FPartida.Aguardar;
end;

procedure TfrmPong.SrvConnected(Sender: TObject; AConnId: TPipeConnectionId);
begin
  // Conexao aceita ainda nao e' jogador: quem entra na partida e' o OI.
  Log('conexao ' + IntToStr(AConnId) + ' aberta - aguardando identificacao.');
end;

procedure TfrmPong.SrvMessage(Sender: TObject; AConnId: TPipeConnectionId;
  const AData: TBytes);
var
  LLinha: string;
begin
  LLinha := PipeUtf8Decode(AData);
  try
    case PongMsgKindOf(LLinha) of
      pmkOi: TratarOi(AConnId, LLinha);
      pmkEntrada: TratarEntrada(AConnId, LLinha);
    else
      Log('conexao ' + IntToStr(AConnId) + ' mandou algo fora de papel: ' +
        LLinha);
    end;
  except
    // Cliente falando errado nao pode derrubar o servidor.
    on E: Exception do
      Log('mensagem invalida da conexao ' + IntToStr(AConnId) + ': ' +
        E.Message);
  end;
end;

procedure TfrmPong.TratarOi(AConnId: TPipeConnectionId; const ALinha: string);
var
  LToken, LApelido: string;
  LAnterior: TPipeConnectionId;
begin
  PongDecodeOi(ALinha, LToken, LApelido);

  // A vaga e' do computador nesta partida: recusa com motivo, como qualquer
  // outra regra de negocio.
  if FBotConvidado then
  begin
    Log('conexao ' + IntToStr(AConnId) +
      ' recusada: a vaga do convidado esta com o computador.');
    EnviarPara(AConnId,
      PongEncodeRecusado('a vaga do convidado esta com o computador'));
    FServer.DisconnectClient(AConnId);
    Exit;
  end;

  // Vaga ocupada por OUTRO jogador.
  if (FVagaConn <> PIPE_INVALID_CONNECTION) and (FVagaConn <> AConnId) and
     (FVagaToken <> LToken) then
  begin
    Log('conexao ' + IntToStr(AConnId) + ' recusada: partida cheia.');
    EnviarPara(AConnId, PongEncodeRecusado('a partida ja tem dois jogadores'));
    FServer.DisconnectClient(AConnId);
    Exit;
  end;

  // Mesmo token numa conexao NOVA: o jogador voltou. A conexao anterior
  // costuma continuar registrada aqui — o TCP dela morreu em silencio e ainda
  // nao foi declarado morto. Derrubar e' obrigatorio, senao a vaga fica presa
  // a um socket que nunca mais responde.
  LAnterior := FVagaConn;
  if (LAnterior <> PIPE_INVALID_CONNECTION) and (LAnterior <> AConnId) then
  begin
    Log('mesmo token numa conexao nova: derrubando a anterior (' +
      IntToStr(LAnterior) + ').');
    FServer.DisconnectClient(LAnterior);
  end;

  if (FVagaToken = LToken) and (LAnterior <> AConnId) then
    Log(LApelido + ' voltou (reconexao) - a partida continua de onde parou.')
  else
    Log(LApelido + ' entrou na partida pela conexao ' + IntToStr(AConnId) + '.');

  FVagaConn := AConnId;
  FVagaToken := LToken;
  FApelido1 := LApelido;
  // Quem acabou de chegar nao esta' segurando tecla nenhuma. Sem isso, uma
  // reconexao no meio de um movimento deixaria a raquete dele correndo sozinha
  // ate' a primeira ENTRADA nova.
  FPartida.DefinirEntrada(1, 0);

  EnviarPara(AConnId, PongEncodeAceito(1));
  AvaliarPresenca;
  EnviarEstado; // fotografia inteira: e' o que faz a reconexao ser indolor
  AtualizarUi;
end;

procedure TfrmPong.TratarEntrada(AConnId: TPipeConnectionId;
  const ALinha: string);
begin
  if AConnId <> FVagaConn then
  begin
    EnviarPara(AConnId, PongEncodeAviso('voce nao esta nesta partida'));
    Exit;
  end;
  // A entrada que veio do fio passa pela MESMA porta do teclado local. Repare
  // que o convidado NAO mexe na posicao da raquete dele: ele so' diz que
  // direcao esta' segurando, e quem integra isso e' a fisica daqui.
  FPartida.DefinirEntrada(1, PongDecodeEntrada(ALinha));
end;

procedure TfrmPong.SrvDisconnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  if AConnId <> FVagaConn then
  begin
    Log('conexao ' + IntToStr(AConnId) + ' saiu (nao ocupava a vaga).');
    Exit;
  end;

  // A vaga esvazia mas o TOKEN fica guardado: e' ele que devolve a partida em
  // andamento a quem voltar.
  FVagaConn := PIPE_INVALID_CONNECTION;
  FPartida.DefinirEntrada(1, 0); // a raquete orfa para de andar
  AvaliarPresenca;
  Log(FApelido1 + ' caiu - a partida fica guardada para o token dele.');
  AtualizarUi;
end;

procedure TfrmPong.EnviarPara(AConnId: TPipeConnectionId;
  const ALinha: string);
begin
  try
    FServer.SendText(AConnId, ALinha);
  except
    // A conexao pode ter morrido entre o evento e este envio; o proprio reader
    // vai notificar a saida.
    on E: EPipeError do
      Log('falha ao enviar para a conexao ' + IntToStr(AConnId) + ': ' +
        E.Message);
  end;
end;

procedure TfrmPong.EnviarEstado;
var
  LEstado: TPongEstado;
begin
  if FServer = nil then
    Exit;
  FPartida.Capturar(LEstado);
  // Broadcast engole falha de conexao individual (o reader dela e' quem avisa),
  // entao isto pode rodar 31x por segundo sem virar cascata de excecao.
  FServer.BroadcastText(PongEncodeEstado(LEstado, FApelido0, FApelido1));
end;

procedure TfrmPong.btnNovaPartidaClick(Sender: TObject);
begin
  // So' a autoridade recomeca; o convidado recebe pelo ESTADO.
  FPartida.Reiniciar;
  AvaliarPresenca;
  Log('nova partida.');
  EnviarEstado;
  AtualizarUi;
end;

{ --- papel de convidado (cliente, espelho da autoridade) --- }

procedure TfrmPong.btnEntrarClick(Sender: TObject);
begin
  FreeAndNil(FPartida);
  FPartida := TPongPartida.Create(False); // espelho: preve, mas nao decide
  FMeuIndice := PONG_SEM_JOGADOR; // so' virei jogador quando o ACEITO chegar
  FBotPorMim := chkBotPorMim.Checked;
  FBotConvidado := False; // so' faz sentido para quem hospeda
  FDificuldade := PongDificuldadeDeIndice(cbDificuldade.ItemIndex);
  FApelido1 := ApelidoOuPadrao('Convidado');
  if FBotPorMim then
    FApelido1 := FApelido1 + ' (computador)';
  FMinhaDirecao := 0;
  FCimaPress := False;
  FBaixoPress := False;
  FUltimoSnapshotMs := 0;
  FUltimoTickAplicado := -1;
  FSemSinal := False;

  FClient := TPipeClient.Create(Trim(edtEndereco.Text), TransporteEscolhido);
  FClient.DispatchMode := pdmMainThread;
  FClient.AutoReconnect := True;
  FClient.MaxReconnectAttempts := 0;
  FClient.OnMessage := CliMessage;
  FClient.OnConnected := CliConnected;
  FClient.OnDisconnected := CliDisconnected;
  FClient.OnError := AnyError;
  try
    FClient.Connect(3000); // blocante ate' 3s: aceitavel num clique de sample
  except
    FreeAndNil(FClient);
    raise;
  end;

  LigarRelogio;
  AtualizarUi;
end;

procedure TfrmPong.CliConnected(Sender: TObject; AConnId: TPipeConnectionId);
begin
  // Dispara no Connect E em cada reconexao automatica. Reidentificar-se aqui
  // (e nao no clique do botao) e' o que faz a vaga voltar sozinha depois de
  // uma queda: para o hospedeiro, "quem sou eu" e' o token, nao a conexao.
  Log('conectado - enviando identificacao.');

  // O hospedeiro pode ter sido REINICIADO enquanto o AutoReconnect tentava, e
  // ai' os ticks dele recomecam do zero. Zerar a referencia aqui e' o que
  // impede a guarda de "snapshot mais novo" de rejeitar a sessao nova inteira.
  FUltimoTickAplicado := -1;
  FUltimoSnapshotMs := 0;
  FSemSinal := False;

  try
    FClient.SendText(PongEncodeOi(FToken, FApelido1));
    // A direcao que eu estava segurando nao sobreviveu do outro lado: o
    // hospedeiro me tratou como recem-chegado (ver TratarOi). Reenviar so' se
    // nao for zero.
    if FMinhaDirecao <> 0 then
      FClient.SendText(PongEncodeEntrada(FMinhaDirecao));
  except
    on E: EPipeError do
      Log('falha ao enviar identificacao: ' + E.Message);
  end;
  AtualizarUi;
end;

procedure TfrmPong.CliMessage(Sender: TObject; AConnId: TPipeConnectionId;
  const AData: TBytes);
var
  LLinha, LTexto: string;
  LEstado: TPongEstado;
begin
  LLinha := PipeUtf8Decode(AData);
  try
    case PongMsgKindOf(LLinha) of
      pmkAceito:
        begin
          FMeuIndice := PongDecodeAceito(LLinha);
          Log('aceito na partida como jogador ' + IntToStr(FMeuIndice + 1) +
            '.');
        end;
      pmkEstado:
        begin
          PongDecodeEstado(LLinha, LEstado, FApelido0, FApelido1);
          // O transporte entrega em ordem, entao um ESTADO nunca chega
          // atrasado em relacao a outro; a guarda existe para o caso do
          // hospedeiro reiniciado (ver CliConnected), em que os ticks voltam
          // atras e um snapshot antigo apareceria como "novo".
          if LEstado.Tick <= FUltimoTickAplicado then
            Exit;
          FUltimoTickAplicado := LEstado.Tick;
          FUltimoSnapshotMs := GetTickCount64;
          FSemSinal := False;

          FPartida.Aplicar(LEstado);
          // A autoridade tambem devolve a MINHA direcao, mas a dela e' mais
          // velha que a tecla que estou segurando agora. Reafirmar evita que a
          // raquete "solte" por um quadro a cada snapshot.
          if FMeuIndice >= 0 then
            FPartida.DefinirEntrada(FMeuIndice, FMinhaDirecao);
        end;
      pmkAviso:
        Log('hospedeiro: ' + PongDecodeTexto(LLinha));
      pmkRecusado:
        begin
          LTexto := PongDecodeTexto(LLinha);
          Log('entrada recusada: ' + LTexto);
          PedirDesligamento('recusado: ' + LTexto);
          Exit;
        end;
    else
      Log('mensagem fora de papel do hospedeiro: ' + LLinha);
    end;
  except
    on E: Exception do
      Log('mensagem invalida do hospedeiro: ' + E.Message);
  end;
end;

procedure TfrmPong.CliDisconnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  Log('conexao caiu - AutoReconnect tentando de novo...');
  AtualizarUi;
end;

procedure TfrmPong.AnyError(Sender: TObject; AConnId: TPipeConnectionId;
  const AError: string);
begin
  Log('erro: ' + AError);
end;

{ --- desligar --- }

procedure TfrmPong.PedirDesligamento(const AMotivo: string);
begin
  // Desligar de dentro de um callback significaria destruir o proprio objeto
  // que esta' entregando o evento. Um TTimer joga o Free para o proximo giro
  // do loop de mensagens, ja' fora do callback. AutoReconnect e' desligado
  // AGORA para que o cliente nao volte a bater na porta no intervalo.
  if FClient <> nil then
    FClient.AutoReconnect := False;
  FMotivoDesligar := AMotivo;
  tmrDesligar.Enabled := True;
end;

procedure TfrmPong.tmrDesligarTimer(Sender: TObject);
begin
  tmrDesligar.Enabled := False;
  Desligar;
  lblStatus.Caption := FMotivoDesligar;
end;

procedure TfrmPong.Desligar;
begin
  tmrJogo.Enabled := False;
  FreeAndNil(FClient); // Disconnect sincrono no destructor
  FreeAndNil(FServer); // Stop sincrono no destructor
  FMeuIndice := PONG_SEM_JOGADOR;
  FVagaConn := PIPE_INVALID_CONNECTION;
  FVagaToken := '';
  FMinhaDirecao := 0;
  FCimaPress := False;
  FBaixoPress := False;
  FSemSinal := False;
  FPartida.Aguardar;
  AtualizarUi;
  pbCampo.Invalidate;
end;

procedure TfrmPong.btnSairClick(Sender: TObject);
begin
  FMotivoDesligar := 'parado';
  Desligar;
  Log('desligado.');
  lblStatus.Caption := FMotivoDesligar;
end;

procedure TfrmPong.cbTransporteChange(Sender: TObject);
begin
  if EstouLigado then
    Exit;
  if TransporteEscolhido = ptTcp then
    edtEndereco.Text := ENDERECO_TCP_PADRAO
  else
    edtEndereco.Text := ENDERECO_LOCAL_PADRAO;
end;

{ --- UI --- }

procedure TfrmPong.AtualizarUi;
var
  LLigado: Boolean;
begin
  LLigado := EstouLigado;
  btnHospedar.Enabled := not LLigado;
  btnEntrar.Enabled := not LLigado;
  btnSair.Enabled := LLigado;
  btnNovaPartida.Enabled := SouHospedeiro;
  edtEndereco.Enabled := not LLigado;
  edtApelido.Enabled := not LLigado;
  chkBotPorMim.Enabled := not LLigado;
  chkBotConvidado.Enabled := not LLigado;
  cbTransporte.Enabled := not LLigado;
  cbDificuldade.Enabled := not LLigado;

  if SouHospedeiro then
    lblStatus.Caption := 'hospedando em "' + FServer.Address + '"'
  else if FClient <> nil then
  begin
    if not FClient.Connected then
      lblStatus.Caption := 'reconectando...'
    else if FMeuIndice < 0 then
      lblStatus.Caption := 'conectado - aguardando aceite'
    else
      lblStatus.Caption := 'jogando em "' + FClient.Address + '"';
  end
  else
    lblStatus.Caption := FMotivoDesligar;

  pbCampo.Invalidate;
end;

procedure TfrmPong.CalcularLayout;
var
  LEscalaY: Double;
begin
  // Letterbox: a MESMA escala nos dois eixos, senao o campo distorce e o
  // angulo que o jogador ve nao e' o angulo que a fisica calculou.
  FEscala := pbCampo.Width / PONG_MUNDO_LARGURA;
  LEscalaY := pbCampo.Height / PONG_MUNDO_ALTURA;
  if LEscalaY < FEscala then
    FEscala := LEscalaY;
  if FEscala <= 0 then
    FEscala := 0.001;
  FOrigemX := (pbCampo.Width - PONG_MUNDO_LARGURA * FEscala) / 2;
  FOrigemY := (pbCampo.Height - PONG_MUNDO_ALTURA * FEscala) / 2;
end;

function TfrmPong.PX(AMundoX: Double): Integer;
begin
  Result := Round(FOrigemX + AMundoX * FEscala);
end;

function TfrmPong.PY(AMundoY: Double): Integer;
begin
  Result := Round(FOrigemY + AMundoY * FEscala);
end;

function TfrmPong.PE(AMundo: Double): Integer;
begin
  Result := Round(AMundo * FEscala);
  if Result < 1 then
    Result := 1;
end;

procedure TfrmPong.pbCampoPaint(Sender: TObject);
var
  LCanvas: TCanvas;
  LIdx, LX, LY, LRaio, LMeia, LLarg: Integer;
  LTexto: string;
  LFundo: TColor;
begin
  LCanvas := pbCampo.Canvas;
  CalcularLayout;

  LFundo := Cor(24, 26, 34);
  LCanvas.Brush.Style := bsSolid;
  LCanvas.Brush.Color := LFundo;
  LCanvas.Pen.Style := psClear;
  LCanvas.FillRect(Rect(0, 0, pbCampo.Width, pbCampo.Height));

  // Campo
  LCanvas.Brush.Color := Cor(28, 30, 42);
  LCanvas.FillRect(Rect(PX(0), PY(0),
    PX(PONG_MUNDO_LARGURA), PY(PONG_MUNDO_ALTURA)));

  // Linha central tracejada
  LCanvas.Brush.Color := Cor(48, 52, 68);
  LY := 0;
  while LY < Round(PONG_MUNDO_ALTURA) do
  begin
    LCanvas.FillRect(Rect(
      PX(PONG_MUNDO_LARGURA / 2 - 2), PY(LY),
      PX(PONG_MUNDO_LARGURA / 2 + 2), PY(LY + 16)));
    Inc(LY, 30);
  end;

  // Raquetes
  LMeia := PE(PONG_RAQUETE_ALTURA / 2);
  LLarg := PE(PONG_RAQUETE_LARGURA);
  for LIdx := 0 to 1 do
  begin
    LCanvas.Brush.Color := CorDoJogador(LIdx);
    if LIdx = 0 then
      LX := PX(PONG_RAQUETE_MARGEM)
    else
      LX := PX(PONG_MUNDO_LARGURA - PONG_RAQUETE_MARGEM - PONG_RAQUETE_LARGURA);
    LCanvas.FillRect(Rect(
      LX, PY(FPartida.RaqueteY[LIdx]) - LMeia,
      LX + LLarg, PY(FPartida.RaqueteY[LIdx]) + LMeia));
  end;

  // Bola (some enquanto ninguem sacou, para nao parecer travada)
  if FPartida.Fase = pfJogando then
  begin
    LRaio := PE(PONG_BOLA_RAIO);
    LCanvas.Brush.Color := Cor(235, 237, 243);
    LCanvas.Pen.Style := psSolid;
    LCanvas.Pen.Color := Cor(235, 237, 243);
    LCanvas.Ellipse(
      PX(FPartida.BolaX) - LRaio, PY(FPartida.BolaY) - LRaio,
      PX(FPartida.BolaX) + LRaio, PY(FPartida.BolaY) + LRaio);
    LCanvas.Pen.Style := psClear;
  end;

  // Placar
  LCanvas.Brush.Style := bsClear;
  LCanvas.Font.Name := 'Consolas';
  LCanvas.Font.Size := 26;
  LCanvas.Font.Style := [fsBold];
  LCanvas.Font.Color := CorDoJogador(0);
  LCanvas.TextOut(PX(PONG_MUNDO_LARGURA / 2) - PE(70) -
    LCanvas.TextWidth(IntToStr(FPartida.Placar[0])), PY(20),
    IntToStr(FPartida.Placar[0]));
  LCanvas.Font.Color := CorDoJogador(1);
  LCanvas.TextOut(PX(PONG_MUNDO_LARGURA / 2) + PE(70), PY(20),
    IntToStr(FPartida.Placar[1]));

  // Nomes
  LCanvas.Font.Size := 10;
  LCanvas.Font.Style := [];
  LCanvas.Font.Color := CorDoJogador(0);
  LCanvas.TextOut(PX(24), PY(20), FApelido0);
  LCanvas.Font.Color := CorDoJogador(1);
  LCanvas.TextOut(
    PX(PONG_MUNDO_LARGURA - 24) - LCanvas.TextWidth(NomeConvidado),
    PY(20), NomeConvidado);

  // Recado do meio do campo
  LTexto := '';
  if FSemSinal then
    LTexto := 'sem sinal do hospedeiro - previsao congelada'
  else if FPartida.Fase = pfTerminada then
  begin
    case FPartida.Vencedor of
      0: LTexto := 'Fim: ' + FApelido0 + ' venceu';
      1: LTexto := 'Fim: ' + NomeConvidado + ' venceu';
    else
      LTexto := 'Fim de partida';
    end;
  end
  else if FPartida.Fase = pfAguardando then
  begin
    if EstouLigado then
      LTexto := 'aguardando o outro jogador...'
    else
      LTexto := 'Hospedar, ou Entrar no endereco de quem hospeda';
  end
  else if FPartida.Fase = pfServindo then
    LTexto := 'saque em ' + IntToStr((FPartida.EsperaMs div 1000) + 1) + '...';

  if LTexto <> '' then
  begin
    LCanvas.Font.Size := 13;
    LCanvas.Font.Style := [fsBold];
    LCanvas.Font.Color := Cor(198, 201, 212);
    LCanvas.TextOut(
      (pbCampo.Width - LCanvas.TextWidth(LTexto)) div 2,
      PY(PONG_MUNDO_ALTURA / 2) - LCanvas.TextHeight(LTexto) - PE(14),
      LTexto);
  end;

  LCanvas.Brush.Style := bsSolid;
  LCanvas.Pen.Style := psSolid;
  LCanvas.Font.Style := [];
end;

end.
