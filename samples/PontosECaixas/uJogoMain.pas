unit uJogoMain;

{ Pontos e Caixas (dots and boxes) para dois jogadores em rede, com UI (VCL no
  Delphi, LCL no Lazarus) a partir do MESMO fonte.

  Um jogador clica em "Hospedar" e vira o servidor da partida; o outro digita
  o endereco dele, clica em "Entrar" e joga junto. O transporte e' escolhido no
  combo: ptLocal (duas janelas na mesma maquina) ou ptTcp (duas maquinas).
  Trocar de um para o outro nao muda uma linha do codigo do jogo — so' o valor
  de Transport e o formato de Address.

  O QUE ESTE SAMPLE MOSTRA, e que os outros nao mostram:

  1. SERVIDOR AUTORITATIVO. O hospedeiro tem a unica instancia de TJogoPartida
     que vale. O convidado nao aplica a propria jogada: ele PEDE (JOGADA) e
     espera o ESTADO voltar. Por isso jogar fora da vez, clicar numa aresta ja
     jogada ou mandar coordenada fora do tabuleiro nao corrompe nada — quem
     recusa e' TJogoPartida.TentarJogar, no hospedeiro, para os dois jogadores
     pelo mesmo caminho.

  2. RECONEXAO QUE DEVOLVE A VAGA. O convidado usa AutoReconnect e se
     reidentifica com um token no OnConnected — que a lib dispara de novo a
     cada reconexao. O hospedeiro reconhece o token, devolve a vaga e manda o
     tabuleiro inteiro: a partida continua de onde parou. Feche a janela do
     convidado no meio do jogo e reabra para ver.

  3. DUAS CAMADAS DE RECUSA, com papeis diferentes. MaxClients = 2 e' teto de
     RECURSO (a lib nem le quem passa disso). "A partida ja tem dois
     jogadores" e' regra de NEGOCIO, aplicada no OI, e por isso consegue
     mandar o motivo antes de desligar. Um teto so' nao daria a mensagem; a
     regra so' nao daria o teto.

  4. ESTADO COMPLETO NAO DIZ O QUE MUDOU. O convidado recebe a posicao pronta,
     entao, sozinho, ele nao saberia ONDE o adversario jogou — a aresta apenas
     apareceria no tabuleiro. Por isso o ESTADO carrega tambem a ultima aresta
     jogada, e a UI a realca por ~0,6s. E' o preco de sincronizar por estado em
     vez de por evento, e ele se paga com um campo.

  5. A CONEXAO ZUMBI DA RECONEXAO. Quando o mesmo token chega numa conexao
     nova, a antiga costuma ainda estar viva do lado do servidor (o TCP dela
     morreu em silencio — tipico de VPN/NAT). O tratamento do OI derruba a
     anterior com DisconnectClient antes de aceitar a nova; sem isso a vaga
     ficaria presa a um socket que nunca mais responde.

  JOGADOR CONTROLADO PELO COMPUTADOR (Jogo.Ia.pas): duas marcacoes, escolhidas
  ao Hospedar/Entrar. "Computador joga por mim" vale nos DOIS papeis — e no
  convidado ela e' a mais interessante, porque o bot vira um cliente autonomo
  mandando JOGADA pela rede, sujeito a mesma validacao de qualquer humano.
  "Computador ocupa a vaga do convidado" e' so' do hospedeiro e da' a partida
  solo. Marcando as duas, a partida roda sozinha.

  Note que a IA NAO tem caminho privilegiado: ela escolhe uma aresta e entra
  pela mesma porta do clique (JogarLocal / AplicarJogadaDoConvidado). Uma IA
  que aplicasse a propria jogada direto no tabuleiro seria a primeira a
  quebrar a autoridade descrita no item 1.

  THREADING: DispatchMode = pdmMainThread nos dois papeis, entao TODO o estado
  do jogo (FPartida, FVagaConn, FApelidos) e' tocado apenas na thread da UI —
  nao ha um unico lock neste fonte, e nao e' descuido: e' o que o pdmMainThread
  compra. A contrapartida esta' em PedirDesligamento, abaixo.

  Regras e protocolo ficam em units puras (Jogo.Partida, Jogo.Protocolo); aqui
  so' ha UI e rede. }

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
  Jogo.Partida, Jogo.Protocolo, Jogo.Ia;

type
  TfrmJogo = class(TForm)
    lblEndereco: TLabel;
    edtEndereco: TEdit;
    cbTransporte: TComboBox;
    lblApelido: TLabel;
    edtApelido: TEdit;
    lblTamanho: TLabel;
    cbTamanho: TComboBox;
    btnHospedar: TButton;
    btnEntrar: TButton;
    btnSair: TButton;
    btnNovaPartida: TButton;
    chkBotPorMim: TCheckBox;
    chkBotConvidado: TCheckBox;
    lblStatus: TLabel;
    lblJogador0: TLabel;
    lblVez: TLabel;
    lblJogador1: TLabel;
    pbTabuleiro: TPaintBox;
    memoLog: TMemo;
    tmrDesligar: TTimer;
    tmrAnimacao: TTimer;
    tmrBot: TTimer;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure btnHospedarClick(Sender: TObject);
    procedure btnEntrarClick(Sender: TObject);
    procedure btnSairClick(Sender: TObject);
    procedure btnNovaPartidaClick(Sender: TObject);
    procedure cbTransporteChange(Sender: TObject);
    procedure pbTabuleiroPaint(Sender: TObject);
    procedure pbTabuleiroMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure pbTabuleiroMouseMove(Sender: TObject; Shift: TShiftState;
      X, Y: Integer);
    procedure tmrDesligarTimer(Sender: TObject);
    procedure tmrAnimacaoTimer(Sender: TObject);
    procedure tmrBotTimer(Sender: TObject);
  private
    FServer: TPipeServer;   // <> nil = sou o hospedeiro
    FClient: TPipeClient;   // <> nil = sou o convidado
    FPartida: TJogoPartida;
    FMeuIndice: Integer;    // 0 hospedeiro, 1 convidado, JOGO_SEM_DONO = fora
    FToken: string;         // identidade de reconexao (convidado)
    FApelido0: string;
    FApelido1: string;
    FVagaConn: TPipeConnectionId; // conexao que ocupa a vaga do convidado
    FVagaToken: string;           // token de quem ocupa/ocupou a vaga
    // Quem o computador controla nesta sessao. Lidos das caixas de marcacao no
    // Hospedar/Entrar (dai' em diante nao mudam: trocar de jogador no meio da
    // partida so' confundiria quem esta' do outro lado).
    FBotPorMim: Boolean;      // o bot joga o MEU jogador (vale nos dois papeis)
    FBotConvidado: Boolean;   // so' hospedeiro: o bot OCUPA a vaga do convidado
    FHover: TJogoAresta;
    FTemHover: Boolean;
    // Realce da jogada que acabou de acontecer. Sem ele a jogada do adversario
    // simplesmente aparece no tabuleiro e o jogador nao ve ONDE foi.
    FAnimAresta: TJogoAresta;
    FAnimAtiva: Boolean;
    FAnimInicio: UInt64;
    // Convidado: qual jogada ja' foi destacada. O ESTADO chega inteiro e pode
    // se repetir (reconexao, entrada de outro cliente); comparar com esta evita
    // reanimar algo que o jogador ja' viu.
    FUltimaVista: TJogoAresta;
    FTemUltimaVista: Boolean;
    // Layout do tabuleiro em pixels, recalculado a cada Paint/clique.
    FCelula: Double;
    FOrigemX: Double;
    FOrigemY: Double;
    FMotivoDesligar: string;

    procedure Log(const ATexto: string);
    function SouHospedeiro: Boolean;
    function EstouLigado: Boolean;
    function TransporteEscolhido: TPipeTransport;
    function TamanhoEscolhido: Integer;
    function ApelidoOuPadrao(const APadrao: string): string;
    function NomeConvidado: string;
    function PossoJogar: Boolean;

    procedure CalcularLayout;
    procedure IniciarAnimacao(const AAresta: TJogoAresta);
    /// Convidado: decide se o ESTADO que acabou de chegar traz jogada NOVA.
    procedure RealcarJogadaRecebida;
    procedure PararAnimacao;
    /// Progresso 0..1 do realce; False quando nao ha animacao em curso.
    function ProgressoAnimacao(out AProgresso: Double): Boolean;
    procedure AtualizarUi;
    procedure Desligar;
    /// Agenda o desligamento para FORA do callback (ver comentario no corpo).
    procedure PedirDesligamento(const AMotivo: string);
    procedure EnviarEstado;
    procedure JogarLocal(const AAresta: TJogoAresta);
    /// Aplica (como autoridade) uma jogada do jogador 1. Serve tanto para a
    /// JOGADA que chegou pela rede quanto para o bot que ocupa a vaga.
    function AplicarJogadaDoConvidado(const AAresta: TJogoAresta;
      out AMotivo: string): Boolean;
    /// True se a vez atual e' de um jogador que ESTA MAQUINA controla por IA.
    function VezDeBotLocal: Boolean;
    /// Arma (ou desarma) a pausa antes da jogada do bot.
    procedure AvaliarVezDoBot;

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
    procedure TratarJogada(AConnId: TPipeConnectionId; const ALinha: string);
    procedure EnviarPara(AConnId: TPipeConnectionId; const ALinha: string);
  end;

var
  frmJogo: TfrmJogo;

implementation

{$IFDEF FPC}
  {$R *.lfm}
{$ELSE}
  {$R *.dfm}
{$ENDIF}

const
  ENDERECO_LOCAL_PADRAO = 'pipes_faa_jogo';
  ENDERECO_TCP_PADRAO = '127.0.0.1:5099';

  MARGEM_TABULEIRO = 24;
  CELULA_MAXIMA = 110;
  RAIO_PONTO = 5;
  ESPESSURA_ARESTA = 6;
  ESPESSURA_LIVRE = 2;
  TOLERANCIA_CLIQUE = 14;

  // Realce da ultima jogada — os mesmos numeros da versao original em Python.
  ANIM_DURACAO_MS = 650;
  ANIM_RAIO_MAX = 22;
  ANIM_ANEL_ESPESSURA = 3;
  ANIM_ARESTA_EXTRA = 4;

{ Paleta escura, a mesma do jogo original. TColor e' BGR nas duas RTLs, entao
  este helper evita depender de RGB() (Windows) ou RGBToColor() (LCL). }
function Cor(R, G, B: Byte): TColor;
begin
  Result := TColor(R or (G shl 8) or (B shl 16));
end;

function Mistura(ACor, AFundo: TColor; APeso: Double): TColor;
var
  LR, LG, LB: Byte;
begin
  LR := Round((ACor and $FF) * APeso + (AFundo and $FF) * (1 - APeso));
  LG := Round(((ACor shr 8) and $FF) * APeso +
              ((AFundo shr 8) and $FF) * (1 - APeso));
  LB := Round(((ACor shr 16) and $FF) * APeso +
              ((AFundo shr 16) and $FF) * (1 - APeso));
  Result := TColor(LR or (LG shl 8) or (LB shl 16));
end;

function CorDoJogador(AIndice: Integer): TColor;
begin
  if AIndice = 0 then
    Result := Cor(57, 135, 229)   // azul
  else
    Result := Cor(217, 89, 38);   // laranja
end;

{ TfrmJogo }

procedure TfrmJogo.FormCreate(Sender: TObject);
begin
  DoubleBuffered := True; // tabuleiro inteiro e' redesenhado a cada jogada
  FPartida := TJogoPartida.Create(5, 5);
  FMeuIndice := JOGO_SEM_DONO;
  FToken := JogoNovoToken;
  FApelido0 := 'Hospedeiro';
  FApelido1 := 'Convidado';
  FVagaConn := PIPE_INVALID_CONNECTION;
  FMotivoDesligar := 'parado';
  cbTransporte.ItemIndex := 0;
  cbTamanho.ItemIndex := 1;
  edtEndereco.Text := ENDERECO_LOCAL_PADRAO;

  Log('Pontos e Caixas em rede.');
  Log('Um lado clica "Hospedar"; o outro digita o endereco e clica "Entrar".');
  Log('Local: as duas janelas na mesma maquina, mesmo nome de pipe.');
  Log('TCP: o hospedeiro pode escutar em 0.0.0.0:5099 (todas as interfaces) e');
  Log('o convidado usa o IP dele, por exemplo 192.168.0.10:5099.');
  AtualizarUi;
end;

procedure TfrmJogo.FormDestroy(Sender: TObject);
begin
  // Eventos pdmMainThread ainda na fila viram no-op depois daqui (objeto-guarda
  // da lib): fechar a janela no meio da partida e' seguro.
  FreeAndNil(FClient);
  FreeAndNil(FServer);
  FreeAndNil(FPartida);
end;

procedure TfrmJogo.Log(const ATexto: string);
begin
  memoLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + ATexto);
end;

function TfrmJogo.SouHospedeiro: Boolean;
begin
  Result := FServer <> nil;
end;

function TfrmJogo.EstouLigado: Boolean;
begin
  Result := (FServer <> nil) or (FClient <> nil);
end;

function TfrmJogo.TransporteEscolhido: TPipeTransport;
begin
  if cbTransporte.ItemIndex = 1 then
    Result := ptTcp
  else
    Result := ptLocal;
end;

function TfrmJogo.TamanhoEscolhido: Integer;
begin
  case cbTamanho.ItemIndex of
    0: Result := 3;
    2: Result := 7;
  else
    Result := 5;
  end;
end;

function TfrmJogo.ApelidoOuPadrao(const APadrao: string): string;
begin
  Result := Trim(edtApelido.Text);
  if Result = '' then
    Result := APadrao;
end;

function TfrmJogo.NomeConvidado: string;
begin
  if not SouHospedeiro then
    Result := FApelido1
  else if FBotConvidado then
    Result := FApelido1 // 'Computador'; nao ha vaga a aguardar
  else if FVagaToken = '' then
    Result := '(aguardando convidado)'
  else if FVagaConn = PIPE_INVALID_CONNECTION then
    Result := FApelido1 + ' (desconectado)'
  else
    Result := FApelido1;
end;

function TfrmJogo.PossoJogar: Boolean;
begin
  // FBotPorMim exclui o clique humano de proposito: com os dois habilitados, o
  // jogador e a IA disputariam a mesma vez.
  Result := EstouLigado and (FMeuIndice >= 0) and (FPartida <> nil) and
    (not FPartida.Terminada) and (FPartida.Vez = FMeuIndice) and
    (not FBotPorMim);
  if Result and not SouHospedeiro then
    // Sem conexao viva o pedido nao chegaria a autoridade; deixar clicar so'
    // daria a impressao de que a jogada valeu.
    Result := (FClient <> nil) and FClient.Connected;
end;

{ --- papel de hospedeiro (servidor, e autoridade da partida) --- }

procedure TfrmJogo.btnHospedarClick(Sender: TObject);
begin
  FPartida.Reiniciar(TamanhoEscolhido, TamanhoEscolhido);
  FMeuIndice := 0;
  // "Ao entrar na partida": as duas marcacoes valem para a sessao inteira.
  FBotPorMim := chkBotPorMim.Checked;
  FBotConvidado := chkBotConvidado.Checked;
  FApelido0 := ApelidoOuPadrao('Hospedeiro');
  if FBotPorMim then
    FApelido0 := FApelido0 + ' (computador)';
  if FBotConvidado then
    FApelido1 := 'Computador'
  else
    FApelido1 := 'Convidado';
  FVagaConn := PIPE_INVALID_CONNECTION;
  FVagaToken := '';

  FServer := TPipeServer.Create(Trim(edtEndereco.Text), TransporteEscolhido);
  FServer.DispatchMode := pdmMainThread;
  // Teto de RECURSO, nao regra do jogo: a vaga de jogador e' UMA, e quem
  // decide isso e' o tratamento do OI. A folga de uma conexao existe para que
  // um terceiro interessado consiga ser ACEITO pelo transporte e receber o
  // "RECUSADO|..." explicando o motivo, em vez de levar um socket fechado na
  // cara sem uma palavra.
  FServer.MaxClients := 2;
  // Em ptTcp o keepalive (padrao 20s) e' o que derruba um convidado que sumiu
  // sem fechar a conexao — sem isso a vaga ficaria ocupada por um fantasma ate
  // o timeout do TCP do sistema, que e' de horas.
  FServer.OnMessage := SrvMessage;
  FServer.OnClientConnected := SrvConnected;
  FServer.OnClientDisconnected := SrvDisconnected;
  FServer.OnError := AnyError;
  try
    FServer.Listen;
  except
    FreeAndNil(FServer);
    FMeuIndice := JOGO_SEM_DONO;
    raise;
  end;

  if FBotConvidado then
    Log('hospedando em "' + FServer.Address +
      '" - a vaga do convidado esta com o computador.')
  else
    Log('hospedando em "' + FServer.Address + '" - aguardando convidado.');
  AtualizarUi;
end;

procedure TfrmJogo.SrvConnected(Sender: TObject; AConnId: TPipeConnectionId);
begin
  // Conexao aceita ainda nao e' jogador: quem entra na partida e' o OI.
  Log('conexao ' + IntToStr(AConnId) + ' aberta - aguardando identificacao.');
end;

procedure TfrmJogo.SrvMessage(Sender: TObject; AConnId: TPipeConnectionId;
  const AData: TBytes);
var
  LLinha: string;
begin
  LLinha := PipeUtf8Decode(AData);
  try
    case JogoMsgKindOf(LLinha) of
      jmkOi: TratarOi(AConnId, LLinha);
      jmkJogada: TratarJogada(AConnId, LLinha);
    else
      // Mensagem que so' o hospedeiro deveria mandar, vinda de um cliente.
      Log('conexao ' + IntToStr(AConnId) + ' mandou algo fora de papel: ' +
        LLinha);
    end;
  except
    // Cliente falando errado nao pode derrubar o servidor: nesta versao ele
    // so' vira linha de log.
    on E: Exception do
      Log('mensagem invalida da conexao ' + IntToStr(AConnId) + ': ' +
        E.Message);
  end;
end;

procedure TfrmJogo.TratarOi(AConnId: TPipeConnectionId; const ALinha: string);
var
  LToken, LApelido: string;
  LAnterior: TPipeConnectionId;
begin
  JogoDecodeOi(ALinha, LToken, LApelido);

  // A vaga do convidado e' do computador nesta partida — nem chega a disputa
  // de token. Recusa com motivo, como qualquer outra regra de negocio.
  if FBotConvidado then
  begin
    Log('conexao ' + IntToStr(AConnId) +
      ' recusada: a vaga do convidado esta com o computador.');
    EnviarPara(AConnId,
      JogoEncodeRecusado('a vaga do convidado esta com o computador'));
    FServer.DisconnectClient(AConnId);
    Exit;
  end;

  // Vaga ocupada por OUTRO jogador: recusa dizendo por que.
  if (FVagaConn <> PIPE_INVALID_CONNECTION) and (FVagaConn <> AConnId) and
     (FVagaToken <> LToken) then
  begin
    Log('conexao ' + IntToStr(AConnId) + ' recusada: partida cheia.');
    EnviarPara(AConnId, JogoEncodeRecusado('a partida ja tem dois jogadores'));
    // Assincrono, e por isso pode ser chamado de dentro deste callback: a lib
    // aborta a conexao e faz a limpeza no pool. O RECUSADO acima ja' foi
    // escrito no socket antes disso.
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
    Log(LApelido + ' entrou na partida pela conexao ' + IntToStr(AConnId) +
      '.');

  FVagaConn := AConnId;
  FVagaToken := LToken;
  FApelido1 := LApelido;

  EnviarPara(AConnId, JogoEncodeAceito(1));
  EnviarEstado; // tabuleiro inteiro: e' o que faz a reconexao ser indolor
end;

procedure TfrmJogo.TratarJogada(AConnId: TPipeConnectionId;
  const ALinha: string);
var
  LAresta: TJogoAresta;
  LMotivo: string;
begin
  if AConnId <> FVagaConn then
  begin
    EnviarPara(AConnId, JogoEncodeAviso('voce nao esta nesta partida'));
    Exit;
  end;

  LAresta := JogoDecodeJogada(ALinha);
  // A jogada que veio do fio passa pela MESMA porta que o clique local — o
  // convidado pede, quem decide e' a partida do hospedeiro.
  if not AplicarJogadaDoConvidado(LAresta, LMotivo) then
  begin
    Log('jogada recusada (' + FApelido1 + '): ' + LMotivo);
    EnviarPara(AConnId, JogoEncodeAviso(LMotivo));
  end;
end;

function TfrmJogo.AplicarJogadaDoConvidado(const AAresta: TJogoAresta;
  out AMotivo: string): Boolean;
begin
  Result := FPartida.TentarJogar(1, AAresta, AMotivo);
  if Result then
  begin
    // O hospedeiro tambem precisa do realce: e' a jogada do ADVERSARIO dele.
    IniciarAnimacao(AAresta);
    EnviarEstado;
  end;
end;

procedure TfrmJogo.SrvDisconnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  if AConnId = FVagaConn then
  begin
    // A vaga esvazia mas o TOKEN fica guardado: e' ele que devolve a partida
    // em andamento a quem voltar. Nao e' reserva exclusiva — enquanto a vaga
    // esta' vazia, outro jogador tambem pode entrar (e ai' assume a partida do
    // jeito que ela esta'). Trocar isso por reserva de verdade seria uma linha
    // aqui, ao custo de uma partida travada quando o convidado nao volta.
    FVagaConn := PIPE_INVALID_CONNECTION;
    Log(FApelido1 + ' caiu - a partida continua guardada para o token dele.');
    AtualizarUi;
  end
  else
    Log('conexao ' + IntToStr(AConnId) + ' saiu (nao ocupava a vaga).');
end;

procedure TfrmJogo.EnviarPara(AConnId: TPipeConnectionId;
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

procedure TfrmJogo.EnviarEstado;
begin
  if FServer <> nil then
    FServer.BroadcastText(JogoEncodeEstado(FPartida, FApelido0, FApelido1));
  AtualizarUi;
end;

procedure TfrmJogo.btnNovaPartidaClick(Sender: TObject);
begin
  // So' a autoridade recomeca a partida; o convidado recebe pelo ESTADO.
  FPartida.Reiniciar(TamanhoEscolhido, TamanhoEscolhido);
  FTemHover := False;
  PararAnimacao;
  Log('nova partida (' + IntToStr(TamanhoEscolhido) + ' x ' +
    IntToStr(TamanhoEscolhido) + ').');
  EnviarEstado;
end;

{ --- papel de convidado (cliente, espelho da autoridade) --- }

procedure TfrmJogo.btnEntrarClick(Sender: TObject);
begin
  FMeuIndice := JOGO_SEM_DONO; // so' virei jogador quando o ACEITO chegar
  FBotPorMim := chkBotPorMim.Checked;
  FBotConvidado := False; // so' faz sentido para quem hospeda
  FApelido1 := ApelidoOuPadrao('Convidado');
  if FBotPorMim then
    FApelido1 := FApelido1 + ' (computador)';

  FClient := TPipeClient.Create(Trim(edtEndereco.Text), TransporteEscolhido);
  FClient.DispatchMode := pdmMainThread;
  // O hospedeiro reiniciou, a VPN piscou, o cabo caiu: volta sozinho e se
  // reidentifica no OnConnected. Sem teto de tentativas neste sample (0).
  FClient.AutoReconnect := True;
  FClient.MaxReconnectAttempts := 0;
  FClient.OnMessage := CliMessage;
  FClient.OnConnected := CliConnected;
  FClient.OnDisconnected := CliDisconnected;
  FClient.OnError := AnyError;
  try
    FClient.Connect(3000); // blocante ate 3s: aceitavel num clique de sample
  except
    FreeAndNil(FClient);
    raise;
  end;

  AtualizarUi;
end;

procedure TfrmJogo.CliConnected(Sender: TObject; AConnId: TPipeConnectionId);
begin
  // Dispara no Connect E em cada reconexao automatica. Reidentificar-se aqui
  // (e nao no clique do botao) e' o que faz a vaga voltar sozinha depois de
  // uma queda: para o hospedeiro, "quem sou eu" e' o token, nao a conexao.
  Log('conectado - enviando identificacao.');
  try
    FClient.SendText(JogoEncodeOi(FToken, FApelido1));
  except
    on E: EPipeError do
      Log('falha ao enviar identificacao: ' + E.Message);
  end;
  AtualizarUi;
end;

procedure TfrmJogo.CliMessage(Sender: TObject; AConnId: TPipeConnectionId;
  const AData: TBytes);
var
  LLinha, LTexto: string;
begin
  LLinha := PipeUtf8Decode(AData);
  try
    case JogoMsgKindOf(LLinha) of
      jmkAceito:
        begin
          FMeuIndice := JogoDecodeAceito(LLinha);
          Log('aceito na partida como jogador ' + IntToStr(FMeuIndice + 1) +
            '.');
        end;
      jmkEstado:
        begin
          // Espelho: aplica o que a autoridade mandou, sem passar por regra.
          JogoDecodeEstado(LLinha, FPartida, FApelido0, FApelido1);
          RealcarJogadaRecebida;
        end;
      jmkAviso:
        Log('hospedeiro: ' + JogoDecodeTexto(LLinha));
      jmkRecusado:
        begin
          LTexto := JogoDecodeTexto(LLinha);
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
  AtualizarUi;
end;

procedure TfrmJogo.CliDisconnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  Log('conexao caiu - AutoReconnect tentando de novo...');
  AtualizarUi;
end;

procedure TfrmJogo.AnyError(Sender: TObject; AConnId: TPipeConnectionId;
  const AError: string);
begin
  Log('erro: ' + AError);
end;

{ --- desligar --- }

procedure TfrmJogo.PedirDesligamento(const AMotivo: string);
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

procedure TfrmJogo.tmrDesligarTimer(Sender: TObject);
begin
  tmrDesligar.Enabled := False;
  Desligar;
  lblStatus.Caption := FMotivoDesligar;
end;

procedure TfrmJogo.Desligar;
begin
  FreeAndNil(FClient); // Disconnect sincrono no destructor
  FreeAndNil(FServer); // Stop sincrono no destructor
  FMeuIndice := JOGO_SEM_DONO;
  FVagaConn := PIPE_INVALID_CONNECTION;
  FVagaToken := '';
  FTemHover := False;
  FTemUltimaVista := False;
  PararAnimacao;
  AtualizarUi;
end;

procedure TfrmJogo.btnSairClick(Sender: TObject);
begin
  FMotivoDesligar := 'parado';
  Desligar;
  Log('desligado.');
  lblStatus.Caption := FMotivoDesligar;
end;

procedure TfrmJogo.cbTransporteChange(Sender: TObject);
begin
  if EstouLigado then
    Exit;
  if TransporteEscolhido = ptTcp then
    edtEndereco.Text := ENDERECO_TCP_PADRAO
  else
    edtEndereco.Text := ENDERECO_LOCAL_PADRAO;
end;

{ --- UI --- }

procedure TfrmJogo.AtualizarUi;
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
  cbTamanho.Enabled := (not LLigado) or SouHospedeiro;

  lblJogador0.Caption := FApelido0 + ': ' + IntToStr(FPartida.Placar[0]);
  lblJogador0.Font.Color := CorDoJogador(0);
  lblJogador1.Caption := NomeConvidado + ': ' + IntToStr(FPartida.Placar[1]);
  lblJogador1.Font.Color := CorDoJogador(1);

  if FPartida.Terminada then
  begin
    lblVez.Caption := 'fim de partida';
    lblVez.Font.Color := clWindowText;
  end
  else
  begin
    if FPartida.Vez = 0 then
      lblVez.Caption := 'Vez de: ' + FApelido0
    else
      lblVez.Caption := 'Vez de: ' + NomeConvidado;
    lblVez.Font.Color := CorDoJogador(FPartida.Vez);
  end;

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

  // Ponto unico de reavaliacao: todo caminho que muda o estado do jogo (jogada
  // local, ESTADO recebido, nova partida, reconexao, desligar) passa por aqui.
  AvaliarVezDoBot;

  pbTabuleiro.Invalidate;
end;

procedure TfrmJogo.CalcularLayout;
var
  LDisp: Double;
begin
  FCelula := (pbTabuleiro.Width - 2 * MARGEM_TABULEIRO) / FPartida.Tabuleiro.Colunas;
  LDisp := (pbTabuleiro.Height - 2 * MARGEM_TABULEIRO) / FPartida.Tabuleiro.Linhas;
  if LDisp < FCelula then
    FCelula := LDisp;
  if FCelula > CELULA_MAXIMA then
    FCelula := CELULA_MAXIMA;
  if FCelula < 1 then
    FCelula := 1;
  FOrigemX := (pbTabuleiro.Width - FCelula * FPartida.Tabuleiro.Colunas) / 2;
  FOrigemY := (pbTabuleiro.Height - FCelula * FPartida.Tabuleiro.Linhas) / 2;
end;

{ --- jogador controlado pelo computador --- }

function TfrmJogo.VezDeBotLocal: Boolean;
begin
  Result := False;
  if (not EstouLigado) or FPartida.Terminada then
    Exit;

  if SouHospedeiro then
  begin
    // O bot que OCUPA a vaga do convidado: a autoridade joga por ele aqui
    // mesmo, sem passar por rede nenhuma.
    if FBotConvidado and (FPartida.Vez = 1) then
      Exit(True);
    // O bot que joga por mim; hospedeiro e' sempre o jogador 0.
    if FBotPorMim and (FPartida.Vez = 0) then
      Exit(True);
    Exit;
  end;

  // Convidado: o bot so' joga depois do ACEITO e com a conexao viva — senao o
  // pedido nao chegaria a autoridade.
  Result := FBotPorMim and (FMeuIndice >= 0) and (FPartida.Vez = FMeuIndice) and
    (FClient <> nil) and FClient.Connected;
end;

procedure TfrmJogo.AvaliarVezDoBot;
begin
  // Desarmar sempre antes: qualquer mudanca de estado (jogada, reconexao,
  // nova partida) reavalia do zero se ha bot para jogar.
  tmrBot.Enabled := False;
  if VezDeBotLocal then
    // A pausa e' proposital: sem ela o bot responde no mesmo instante e o
    // humano nao ve a jogada dele acontecer.
    tmrBot.Enabled := True;
end;

procedure TfrmJogo.tmrBotTimer(Sender: TObject);
var
  LAresta: TJogoAresta;
  LMotivo: string;
begin
  tmrBot.Enabled := False;
  // O estado pode ter mudado durante a pausa (o adversario reconectou, a
  // partida foi reiniciada): reconfere em vez de confiar no que armou o timer.
  if not VezDeBotLocal then
    Exit;
  if not JogoIaEscolherJogada(FPartida.Tabuleiro, LAresta) then
    Exit;

  if SouHospedeiro and (FPartida.Vez = 1) then
    // Bot na vaga do convidado: entra pela MESMA porta que a JOGADA da rede.
    AplicarJogadaDoConvidado(LAresta, LMotivo)
  else
    // Bot jogando por mim: JogarLocal ja' roteia certo (aplica no hospedeiro,
    // manda JOGADA no convidado).
    JogarLocal(LAresta);
end;

{ --- realce da ultima jogada --- }

procedure TfrmJogo.IniciarAnimacao(const AAresta: TJogoAresta);
begin
  FAnimAresta := AAresta;
  FAnimInicio := GetTickCount64;
  FAnimAtiva := True;
  // Uma jogada nova durante o realce da anterior simplesmente reinicia o ciclo.
  tmrAnimacao.Enabled := True;
  pbTabuleiro.Invalidate;
end;

procedure TfrmJogo.RealcarJogadaRecebida;
var
  LUltima: TJogoAresta;
begin
  if not FPartida.TryUltimaJogada(LUltima) then
  begin
    // Partida recem-comecada: nao ha jogada nenhuma para lembrar.
    FTemUltimaVista := False;
    PararAnimacao;
    Exit;
  end;

  // O mesmo ESTADO pode chegar mais de uma vez sem jogada nova no meio (uma
  // reconexao, ou outro cliente entrando fez o hospedeiro republicar). Sem
  // esta comparacao, o realce piscaria de novo numa jogada ja' vista — e, pior,
  // chamaria a atencao do jogador para o lugar errado.
  if FTemUltimaVista and JogoArestaIgual(LUltima, FUltimaVista) then
    Exit;

  FUltimaVista := LUltima;
  FTemUltimaVista := True;
  IniciarAnimacao(LUltima);
end;

procedure TfrmJogo.PararAnimacao;
begin
  FAnimAtiva := False;
  tmrAnimacao.Enabled := False;
end;

function TfrmJogo.ProgressoAnimacao(out AProgresso: Double): Boolean;
var
  LDecorrido: UInt64;
begin
  AProgresso := 0;
  Result := False;
  if not FAnimAtiva then
    Exit;
  LDecorrido := GetTickCount64 - FAnimInicio;
  if LDecorrido >= ANIM_DURACAO_MS then
    Exit;
  AProgresso := LDecorrido / ANIM_DURACAO_MS;
  Result := True;
end;

procedure TfrmJogo.tmrAnimacaoTimer(Sender: TObject);
var
  LProgresso: Double;
begin
  // O timer so' existe enquanto o realce dura: terminou, desliga sozinho e o
  // tabuleiro volta a ser redesenhado apenas quando algo muda.
  if not ProgressoAnimacao(LProgresso) then
    PararAnimacao;
  pbTabuleiro.Invalidate;
end;

procedure TfrmJogo.pbTabuleiroPaint(Sender: TObject);
var
  LCanvas: TCanvas;
  LTab: TJogoTabuleiro;
  LR, LC, LX, LY, LX2, LY2, LDono: Integer;
  LAresta: TJogoAresta;
  LFundo, LFundoTab: TColor;
  LTexto: string;
  LAnimando: Boolean;
  LProgresso, LResto, LSuave, LRaio: Double;

  procedure DesenharAresta(const AAresta: TJogoAresta);
  begin
    LX := Round(FOrigemX + AAresta.Coluna * FCelula);
    LY := Round(FOrigemY + AAresta.Linha * FCelula);
    if AAresta.Lado = jlHorizontal then
    begin
      LX2 := Round(FOrigemX + (AAresta.Coluna + 1) * FCelula);
      LY2 := LY;
    end
    else
    begin
      LX2 := LX;
      LY2 := Round(FOrigemY + (AAresta.Linha + 1) * FCelula);
    end;

    LDono := LTab.DonoAresta(AAresta);
    if LDono <> JOGO_SEM_DONO then
    begin
      if LAnimando and JogoArestaIgual(AAresta, FAnimAresta) then
      begin
        // Clareia em direcao ao branco e engorda, decaindo ao longo do realce.
        LCanvas.Pen.Color := Mistura(Cor(255, 255, 255),
          CorDoJogador(LDono), LResto * 0.6);
        LCanvas.Pen.Width := ESPESSURA_ARESTA +
          Round(LResto * ANIM_ARESTA_EXTRA);
      end
      else
      begin
        LCanvas.Pen.Color := CorDoJogador(LDono);
        LCanvas.Pen.Width := ESPESSURA_ARESTA;
      end;
    end
    else if FTemHover and JogoArestaIgual(AAresta, FHover) and PossoJogar then
    begin
      LCanvas.Pen.Color := Cor(120, 125, 145);
      LCanvas.Pen.Width := ESPESSURA_ARESTA;
    end
    else
    begin
      LCanvas.Pen.Color := Cor(39, 42, 54);
      LCanvas.Pen.Width := ESPESSURA_LIVRE;
    end;
    LCanvas.MoveTo(LX, LY);
    LCanvas.LineTo(LX2, LY2);
  end;

begin
  LCanvas := pbTabuleiro.Canvas;
  LTab := FPartida.Tabuleiro;
  CalcularLayout;

  // A aresta realcada tem que existir E estar jogada: depois de um "nova
  // partida" (ou de um tabuleiro menor) a ultima jogada pode nem caber mais no
  // tabuleiro, e DonoAresta devolve JOGO_SEM_DONO para indice fora da faixa.
  LAnimando := ProgressoAnimacao(LProgresso) and
    (LTab.DonoAresta(FAnimAresta) <> JOGO_SEM_DONO);
  LResto := 1 - LProgresso;

  LFundo := Cor(24, 26, 34);
  LFundoTab := Cor(28, 30, 42);

  LCanvas.Brush.Style := bsSolid;
  LCanvas.Brush.Color := LFundo;
  LCanvas.FillRect(Rect(0, 0, pbTabuleiro.Width, pbTabuleiro.Height));

  LCanvas.Brush.Color := LFundoTab;
  LCanvas.FillRect(Rect(
    Round(FOrigemX) - 14, Round(FOrigemY) - 14,
    Round(FOrigemX + LTab.Colunas * FCelula) + 14,
    Round(FOrigemY + LTab.Linhas * FCelula) + 14));

  // Caixas fechadas: cor do dono esmaecida contra o fundo do tabuleiro.
  LCanvas.Pen.Style := psClear;
  for LR := 0 to LTab.Linhas - 1 do
    for LC := 0 to LTab.Colunas - 1 do
    begin
      LDono := LTab.DonoCaixa[LR, LC];
      if LDono = JOGO_SEM_DONO then
        Continue;
      LCanvas.Brush.Color := Mistura(CorDoJogador(LDono), LFundoTab, 0.55);
      LCanvas.FillRect(Rect(
        Round(FOrigemX + LC * FCelula), Round(FOrigemY + LR * FCelula),
        Round(FOrigemX + (LC + 1) * FCelula),
        Round(FOrigemY + (LR + 1) * FCelula)));
    end;
  LCanvas.Pen.Style := psSolid;

  for LR := 0 to LTab.Linhas do
    for LC := 0 to LTab.Colunas - 1 do
    begin
      LAresta := JogoAresta(jlHorizontal, LR, LC);
      DesenharAresta(LAresta);
    end;
  for LR := 0 to LTab.Linhas - 1 do
    for LC := 0 to LTab.Colunas do
    begin
      LAresta := JogoAresta(jlVertical, LR, LC);
      DesenharAresta(LAresta);
    end;

  LCanvas.Pen.Width := 1;
  LCanvas.Pen.Color := Cor(198, 201, 212);
  LCanvas.Brush.Color := Cor(198, 201, 212);
  for LR := 0 to LTab.Linhas do
    for LC := 0 to LTab.Colunas do
    begin
      LX := Round(FOrigemX + LC * FCelula);
      LY := Round(FOrigemY + LR * FCelula);
      LCanvas.Ellipse(LX - RAIO_PONTO, LY - RAIO_PONTO,
        LX + RAIO_PONTO, LY + RAIO_PONTO);
    end;

  // Aneis que expandem a partir dos dois pontos da jogada, por cima de tudo.
  if LAnimando then
  begin
    LSuave := 1 - LResto * LResto * LResto; // ease-out cubico, como no Python
    LRaio := RAIO_PONTO + LSuave * (ANIM_RAIO_MAX - RAIO_PONTO);
    LDono := LTab.DonoAresta(FAnimAresta);

    LX := Round(FOrigemX + FAnimAresta.Coluna * FCelula);
    LY := Round(FOrigemY + FAnimAresta.Linha * FCelula);
    if FAnimAresta.Lado = jlHorizontal then
    begin
      LX2 := Round(FOrigemX + (FAnimAresta.Coluna + 1) * FCelula);
      LY2 := LY;
    end
    else
    begin
      LX2 := LX;
      LY2 := Round(FOrigemY + (FAnimAresta.Linha + 1) * FCelula);
    end;

    // TCanvas nao tem canal alfa: o esmaecimento e' feito misturando a cor do
    // anel com o fundo do tabuleiro. Sobre uma caixa ja' preenchida o tom sai
    // um pouco fora — e' a simplificacao que evita ter de compor um bitmap
    // com alfa so' para dois aneis.
    LCanvas.Brush.Style := bsClear;
    LCanvas.Pen.Width := ANIM_ANEL_ESPESSURA;
    LCanvas.Pen.Color := Mistura(CorDoJogador(LDono), LFundoTab, LResto);
    LCanvas.Ellipse(LX - Round(LRaio), LY - Round(LRaio),
      LX + Round(LRaio), LY + Round(LRaio));
    LCanvas.Ellipse(LX2 - Round(LRaio), LY2 - Round(LRaio),
      LX2 + Round(LRaio), LY2 + Round(LRaio));
    LCanvas.Brush.Style := bsSolid;
    LCanvas.Pen.Width := 1;
  end;

  if FPartida.Terminada then
  begin
    case FPartida.Vencedor of
      0: LTexto := 'Fim: ' + FApelido0 + ' venceu';
      1: LTexto := 'Fim: ' + NomeConvidado + ' venceu';
    else
      LTexto := 'Fim: empate';
    end;
    LCanvas.Brush.Style := bsClear;
    LCanvas.Font.Color := Cor(230, 232, 238);
    LCanvas.Font.Size := 14;
    LCanvas.Font.Style := [fsBold];
    LCanvas.TextOut((pbTabuleiro.Width - LCanvas.TextWidth(LTexto)) div 2, 4,
      LTexto);
    LCanvas.Font.Style := [];
    LCanvas.Brush.Style := bsSolid;
  end;
end;

procedure TfrmJogo.pbTabuleiroMouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Integer);
var
  LAresta: TJogoAresta;
  LAchou, LMudou: Boolean;
begin
  CalcularLayout;
  LAchou := FPartida.Tabuleiro.AcharArestaLivrePerto(X, Y,
    FOrigemX, FOrigemY, FCelula, TOLERANCIA_CLIQUE, LAresta);
  LMudou := (LAchou <> FTemHover) or
    (LAchou and not JogoArestaIgual(LAresta, FHover));
  FTemHover := LAchou;
  if LAchou then
    FHover := LAresta;
  if LMudou then
    pbTabuleiro.Invalidate;
end;

procedure TfrmJogo.pbTabuleiroMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  LAresta: TJogoAresta;
begin
  if Button <> mbLeft then
    Exit;
  if not PossoJogar then
    Exit;
  CalcularLayout;
  if not FPartida.Tabuleiro.AcharArestaLivrePerto(X, Y,
       FOrigemX, FOrigemY, FCelula, TOLERANCIA_CLIQUE, LAresta) then
    Exit;
  JogarLocal(LAresta);
end;

procedure TfrmJogo.JogarLocal(const AAresta: TJogoAresta);
var
  LMotivo: string;
begin
  if SouHospedeiro then
  begin
    // Sou a autoridade: aplico e publico o resultado.
    if FPartida.TentarJogar(0, AAresta, LMotivo) then
    begin
      IniciarAnimacao(AAresta);
      EnviarEstado;
    end
    else
      Log('jogada recusada: ' + LMotivo);
    Exit;
  end;

  // Sou espelho: PEDE a jogada e espera o ESTADO. De proposito nao aplico
  // localmente "para dar resposta imediata" — seria a porta de entrada da
  // divergencia entre as duas telas.
  try
    FClient.SendText(JogoEncodeJogada(AAresta));
  except
    on E: EPipeError do
      Log('falha ao enviar a jogada: ' + E.Message);
  end;
end;

end.
