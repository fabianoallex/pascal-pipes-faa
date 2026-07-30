unit uMonitorMain;

{ Monitor de topicos: um explorador de pub/sub com UI (VCL no Delphi, LCL no
  Lazarus) a partir do MESMO fonte. Uma janela hospeda, as outras entram.

  Serve como FERRAMENTA, e nao so como demonstracao: com ele da' para depurar o
  pub/sub de qualquer app feito com a lib — assinar um filtro na mao, ver o que
  chega, publicar um valor de teste, reter e conferir o catch-up.

  O que ele mostra e os outros samples nao:

  1. ASSINATURA COMO ESTADO DESEJADO, manipulavel ao vivo. Assine e cancele
     filtros com o app rodando e veja a entrega mudar na hora. Melhor: monte a
     lista com a janela DESCONECTADA (Subscribe funciona sem sessao), conecte
     depois, e ela ja vale — a lib reenvia tudo em cada sessao nova, inclusive
     nas reconexoes automaticas, antes do OnConnected.

  2. O EFEITO DO RelayClientPublish, lado a lado. Duas janelas cliente
     assinando o mesmo topico: com a caixa marcada no hospedeiro, o que uma
     publica alcanca a outra; desmarque e a entrega para na hora. E' a decisao
     central do recurso, e aqui ela e' um clique. (A property nao tem
     EnsureInactive de proposito: pode virar com o servidor no ar.)

  3. O CAMINHO DA RECUSA, que nenhum outro sample exercita. Baixe
     MaxSubscriptions para 1 no hospedeiro e assine dois filtros num cliente: o
     segundo e' recusado, e a recusa aparece nos DOIS lados (OnError aqui e la),
     com a conexao de pe. Digite um filtro invalido ('caixa*', 'a.#.b') e veja
     EPipeError na hora, no proprio Subscribe — erro de programacao aparece na
     linha errada, nao vira frame.

  4. RETIDO MARCADO. A lista de recebidas carimba 'ret' no que veio do cache de
     retidos do servidor. Publique com 'reter' marcado, entre com outra janela,
     assine — o valor cai marcado, sem ninguem publicar de novo. Publique de
     novo com 'reter' para quem JA assina e note que dessa vez chega SEM marca:
     ao vivo nunca e' historico, mesmo quando o publicador pediu retencao.

  5. DUAS VISOES DO MESMO RECURSO no mesmo layout. Hospedando, o painel de
     assinaturas mostra QUEM assinou O QUE (ClientSubscriptions de cada
     conexao) e a contagem de assinantes do topico do campo Publicar — a visao
     do roteador. Como cliente, mostra as proprias assinaturas, editaveis. Um
     monitor de verdade precisa das duas.

  DispatchMode = pdmMainThread: todo handler da lib roda na thread da UI, entao
  este codigo mexe em controles direto, sem Synchronize/Queue. Nao ha lock
  nenhum nesta unit, e isso e' consequencia daquela linha, nao descuido.

  Uma regra que esta unit respeita e vale copiar (a razao esta no cabecalho de
  samples/GatewaySeguro/Gateway.Nucleo.pas): NENHUM Stop/Disconnect/Free de
  dentro de callback da lib. Eles sao sincronos e esperam o join das threads;
  chamados de dentro de um evento, esperariam por si mesmos. Quem desliga e' o
  clique do botao. Handler de queda so' registra e atualiza a tela. }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils,
  Classes,
  Forms,
  Controls,
  StdCtrls,
  ExtCtrls,
  Pipes.Types,
  Pipes.Framing,
  Pipes.Topics,
  Pipes.Server,
  Pipes.Client;

type
  TfrmMonitor = class(TForm)
    lblEndereco: TLabel;
    edEndereco: TEdit;
    cbTransporte: TComboBox;
    btnHospedar: TButton;
    btnEntrar: TButton;
    btnDesligar: TButton;
    lblEstado: TLabel;
    gbServidor: TGroupBox;
    chkRelay: TCheckBox;
    lblMax: TLabel;
    edMax: TEdit;
    btnAplicarMax: TButton;
    lblSrvInfo: TLabel;
    gbAssinaturas: TGroupBox;
    lbSubs: TListBox;
    edFiltro: TEdit;
    btnAssinar: TButton;
    btnCancelar: TButton;
    gbRecebidas: TGroupBox;
    lbRecebidas: TListBox;
    btnLimpar: TButton;
    gbPublicar: TGroupBox;
    lblTopico: TLabel;
    edTopico: TEdit;
    lblTexto: TLabel;
    edTexto: TEdit;
    chkReter: TCheckBox;
    btnPublicar: TButton;
    memoLog: TMemo;
    tmrRefresh: TTimer;
    procedure FormDestroy(Sender: TObject);
    procedure btnHospedarClick(Sender: TObject);
    procedure btnEntrarClick(Sender: TObject);
    procedure btnDesligarClick(Sender: TObject);
    procedure btnAssinarClick(Sender: TObject);
    procedure btnCancelarClick(Sender: TObject);
    procedure btnPublicarClick(Sender: TObject);
    procedure btnLimparClick(Sender: TObject);
    procedure btnAplicarMaxClick(Sender: TObject);
    procedure chkRelayClick(Sender: TObject);
    procedure cbTransporteChange(Sender: TObject);
    procedure tmrRefreshTimer(Sender: TObject);
  private
    // Um dos dois, nunca os dois: esta janela ou hospeda ou entra.
    FServer: TPipeServer;
    FClient: TPipeClient;
    // --- handlers da lib (todos na thread da UI, por pdmMainThread) ---
    procedure OnCliTopico(Sender: TObject; AConnId: TPipeConnectionId;
      const ATopic: string; const AData: TBytes; ARetained: Boolean);
    procedure OnCliConectou(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnCliCaiu(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnSrvPublicou(Sender: TObject; AConnId: TPipeConnectionId;
      const ATopic: string; const AData: TBytes; ARetained: Boolean);
    procedure OnSrvAssinou(Sender: TObject; AConnId: TPipeConnectionId;
      const AFilter: string);
    procedure OnSrvCancelou(Sender: TObject; AConnId: TPipeConnectionId;
      const AFilter: string);
    procedure OnSrvEntrou(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnSrvSaiu(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnErro(Sender: TObject; AConnId: TPipeConnectionId;
      const AError: string);
    // --- UI ---
    procedure Log(const AMsg: string);
    procedure AddRecebida(const ATopic, ATexto: string; ARetained: Boolean);
    procedure AtualizarEstado;
    procedure AtualizarListaDeAssinaturas;
    function Hospedando: Boolean;
    function Entrando: Boolean;
    function TransporteEscolhido: TPipeTransport;
  end;

var
  frmMonitor: TfrmMonitor;

implementation

{$IFDEF FPC}
  {$R *.lfm}
{$ELSE}
  {$R *.dfm}
{$ENDIF}

const
  ENDERECO_LOCAL = 'pipes_faa_monitor';
  ENDERECO_TCP = '127.0.0.1:5000';

{ --- helpers de estado --- }

function TfrmMonitor.Hospedando: Boolean;
begin
  Result := Assigned(FServer);
end;

function TfrmMonitor.Entrando: Boolean;
begin
  Result := Assigned(FClient);
end;

function TfrmMonitor.TransporteEscolhido: TPipeTransport;
begin
  if cbTransporte.ItemIndex = 1 then
    Result := ptTcp
  else
    Result := ptLocal;
end;

procedure TfrmMonitor.Log(const AMsg: string);
begin
  memoLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + AMsg);
end;

procedure TfrmMonitor.AddRecebida(const ATopic, ATexto: string;
  ARetained: Boolean);
var
  LMarca: string;
begin
  // 'ret' e' a distincao que o ARetained do evento carrega: valor guardado que
  // o servidor entregou porque a assinatura acabou de ser feita, e nao algo que
  // acabou de acontecer. Um app real usa isso para nao tocar campainha nem
  // contar venda duas vezes ao reconectar.
  if ARetained then
    LMarca := 'ret  '
  else
    LMarca := '     ';
  lbRecebidas.Items.Add(Format('%s%s  %-28s %s',
    [LMarca, FormatDateTime('hh:nn:ss', Now), ATopic, ATexto]));
  lbRecebidas.ItemIndex := lbRecebidas.Items.Count - 1; // rola para o fim
end;

procedure TfrmMonitor.AtualizarEstado;
var
  LAtivo: Boolean;
begin
  LAtivo := Hospedando or Entrando;
  edEndereco.Enabled := not LAtivo;
  cbTransporte.Enabled := not LAtivo;
  btnHospedar.Enabled := not LAtivo;
  btnEntrar.Enabled := not LAtivo;
  btnDesligar.Enabled := LAtivo;
  gbServidor.Enabled := Hospedando;
  chkRelay.Enabled := Hospedando;
  edMax.Enabled := Hospedando;
  btnAplicarMax.Enabled := Hospedando;
  // Assinar e' coisa de cliente: o servidor nao assina nada, ele ROTEIA. Aqui a
  // lista dele mostra quem assinou o que.
  edFiltro.Enabled := Entrando;
  btnAssinar.Enabled := Entrando;
  btnCancelar.Enabled := Entrando;
  btnPublicar.Enabled := LAtivo;
  chkReter.Enabled := LAtivo;
  tmrRefresh.Enabled := Hospedando;

  if Hospedando then
  begin
    gbAssinaturas.Caption := 'Assinaturas dos clientes (visao do servidor)';
    lblEstado.Caption := 'hospedando';
  end
  else if Entrando then
  begin
    gbAssinaturas.Caption := 'Minhas assinaturas';
    if FClient.Connected then
      lblEstado.Caption := 'conectado'
    else
      lblEstado.Caption := 'reconectando...';
  end
  else
  begin
    gbAssinaturas.Caption := 'Assinaturas';
    lblEstado.Caption := 'parado';
    lblSrvInfo.Caption := '';
  end;
  AtualizarListaDeAssinaturas;
end;

procedure TfrmMonitor.AtualizarListaDeAssinaturas;
var
  LId: TPipeConnectionId;
  LFiltro: string;
  LSel: Integer;
  LTem: Boolean;
begin
  LSel := lbSubs.ItemIndex;
  lbSubs.Items.BeginUpdate;
  try
    lbSubs.Items.Clear;
    if Hospedando then
    begin
      // ClientSubscriptions responde por conexao: e' a visao do roteador, e a
      // unica forma de ver de fora o que cada cliente pediu.
      for LId in FServer.ClientIds do
      begin
        LTem := False;
        for LFiltro in FServer.ClientSubscriptions(LId) do
        begin
          lbSubs.Items.Add(Format('conn %d: %s', [LId, LFiltro]));
          LTem := True;
        end;
        if not LTem then
          lbSubs.Items.Add(Format('conn %d: (nenhuma)', [LId]));
      end;
    end
    else if Entrando then
    begin
      // Subscriptions e' o estado DESEJADO: continua listado com a sessao caida,
      // porque e' exatamente o que sera' reenviado quando ela voltar.
      for LFiltro in FClient.Subscriptions do
        lbSubs.Items.Add(LFiltro);
    end;
  finally
    lbSubs.Items.EndUpdate;
  end;
  if (LSel >= 0) and (LSel < lbSubs.Items.Count) then
    lbSubs.ItemIndex := LSel;
end;

{ --- handlers da lib --- }

procedure TfrmMonitor.OnCliTopico(Sender: TObject; AConnId: TPipeConnectionId;
  const ATopic: string; const AData: TBytes; ARetained: Boolean);
begin
  AddRecebida(ATopic, PipeUtf8Decode(AData), ARetained);
end;

procedure TfrmMonitor.OnCliConectou(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  // As assinaturas de FClient.Subscriptions ja foram reenviadas ANTES deste
  // evento: nao ha nada a reassinar aqui, e e' de proposito que este handler
  // nao chame Subscribe.
  Log('conectado (assinaturas restauradas pela lib)');
  AtualizarEstado;
end;

procedure TfrmMonitor.OnCliCaiu(Sender: TObject; AConnId: TPipeConnectionId);
begin
  if FClient.AutoReconnect then
    Log('desconectado (AutoReconnect vai tentar de novo; as assinaturas ' +
      'continuam listadas — sao estado desejado)')
  else
    Log('desconectado');
  AtualizarEstado;
end;

procedure TfrmMonitor.OnSrvPublicou(Sender: TObject;
  AConnId: TPipeConnectionId; const ATopic: string; const AData: TBytes;
  ARetained: Boolean);
var
  LPedido: string;
begin
  // Do lado do servidor, ARetained e' o PEDIDO do cliente (atendido so' com o
  // relay ligado), nao "veio do cache" — aqui a mensagem acabou de chegar do
  // fio, por definicao. Por isso a lista nao a marca como retida.
  if ARetained then
    LPedido := ', pediu reter'
  else
    LPedido := '';
  AddRecebida(ATopic, Format('%s   [de conn %d%s]',
    [PipeUtf8Decode(AData), AConnId, LPedido]), False);
  if not chkRelay.Checked then
    Log(Format('conn %d publicou em "%s" e NAO foi retransmitido ' +
      '(RelayClientPublish desmarcado)', [AConnId, ATopic]));
end;

procedure TfrmMonitor.OnSrvAssinou(Sender: TObject; AConnId: TPipeConnectionId;
  const AFilter: string);
begin
  // Notificacao: a assinatura ja esta valendo e os retidos que casam com ela ja
  // foram enviados. Para NEGAR, o caminho seria FServer.DisconnectClient(AConnId)
  // — nao ha veto, porque um veto rodaria no pool e reordenaria assinaturas.
  Log(Format('conn %d assinou "%s"', [AConnId, AFilter]));
  AtualizarListaDeAssinaturas;
end;

procedure TfrmMonitor.OnSrvCancelou(Sender: TObject;
  AConnId: TPipeConnectionId; const AFilter: string);
begin
  Log(Format('conn %d cancelou "%s"', [AConnId, AFilter]));
  AtualizarListaDeAssinaturas;
end;

procedure TfrmMonitor.OnSrvEntrou(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log(Format('conn %d entrou (%d cliente(s))', [AConnId, FServer.ClientCount]));
  AtualizarListaDeAssinaturas;
end;

procedure TfrmMonitor.OnSrvSaiu(Sender: TObject; AConnId: TPipeConnectionId);
begin
  // As assinaturas desta conexao morreram com ela; nao ha o que remover.
  Log(Format('conn %d saiu (%d cliente(s))', [AConnId, FServer.ClientCount]));
  AtualizarListaDeAssinaturas;
end;

procedure TfrmMonitor.OnErro(Sender: TObject; AConnId: TPipeConnectionId;
  const AError: string);
begin
  // No CLIENTE, e' aqui que aparece a recusa de uma assinatura pelo servidor
  // (filtro invalido ou teto por cliente): Subscribe nao levanta por isso,
  // porque a resposta vem depois, do outro lado. No SERVIDOR, e' aqui que
  // aparece a mesma recusa do ponto de vista de quem recusou.
  Log('ERRO: ' + AError);
end;

{ --- cliques --- }

procedure TfrmMonitor.cbTransporteChange(Sender: TObject);
begin
  // Ajuda quem troca o combo: os dois transportes tem formato de Address
  // diferente ('MeuPipe' contra 'host:porta'), e o erro so' apareceria no
  // Listen/Connect.
  if TransporteEscolhido = ptTcp then
  begin
    if Pos(':', edEndereco.Text) = 0 then
      edEndereco.Text := ENDERECO_TCP;
  end
  else
    if Pos(':', edEndereco.Text) > 0 then
      edEndereco.Text := ENDERECO_LOCAL;
end;

procedure TfrmMonitor.btnHospedarClick(Sender: TObject);
begin
  FServer := TPipeServer.Create(edEndereco.Text, TransporteEscolhido);
  try
    FServer.DispatchMode := pdmMainThread; // eventos direto na thread da UI
    FServer.RelayClientPublish := chkRelay.Checked;
    FServer.MaxSubscriptionsPerClient := StrToIntDef(edMax.Text,
      PIPES_DEFAULT_MAX_SUBSCRIPTIONS);
    FServer.OnPublish := OnSrvPublicou;
    FServer.OnSubscribe := OnSrvAssinou;
    FServer.OnUnsubscribe := OnSrvCancelou;
    FServer.OnClientConnected := OnSrvEntrou;
    FServer.OnClientDisconnected := OnSrvSaiu;
    FServer.OnError := OnErro;
    FServer.Listen;
  except
    on E: Exception do
    begin
      FreeAndNil(FServer);
      Log('nao consegui hospedar: ' + E.Message);
      AtualizarEstado;
      Exit;
    end;
  end;
  Log('hospedando em "' + edEndereco.Text + '"');
  AtualizarEstado;
end;

procedure TfrmMonitor.btnEntrarClick(Sender: TObject);
begin
  FClient := TPipeClient.Create(edEndereco.Text, TransporteEscolhido);
  try
    FClient.DispatchMode := pdmMainThread;
    FClient.AutoReconnect := True;
    FClient.OnTopicMessage := OnCliTopico;
    FClient.OnConnected := OnCliConectou;
    FClient.OnDisconnected := OnCliCaiu;
    FClient.OnError := OnErro;
    FClient.Connect(3000);
  except
    on E: Exception do
    begin
      FreeAndNil(FClient);
      Log('nao consegui entrar: ' + E.Message);
      AtualizarEstado;
      Exit;
    end;
  end;
  AtualizarEstado;
end;

procedure TfrmMonitor.btnDesligarClick(Sender: TObject);
begin
  // Sincrono, e e' por isso que mora num CLIQUE e nunca num callback da lib.
  tmrRefresh.Enabled := False;
  FreeAndNil(FServer);  // Stop no destructor
  FreeAndNil(FClient);  // Disconnect no destructor
  Log('desligado.');
  AtualizarEstado;
end;

procedure TfrmMonitor.btnAssinarClick(Sender: TObject);
begin
  try
    // Levanta na hora para filtro invalido — 'caixa*', 'a.#.b'. Vale tentar:
    // e' erro de programacao, e o lugar de aparecer e' aqui, nao num frame que
    // o servidor recusaria depois.
    FClient.Subscribe(Trim(edFiltro.Text));
  except
    on E: EPipeError do
    begin
      Log('filtro recusado aqui mesmo: ' + E.Message);
      Exit;
    end;
  end;
  Log('assinei "' + Trim(edFiltro.Text) + '"');
  AtualizarListaDeAssinaturas;
end;

procedure TfrmMonitor.btnCancelarClick(Sender: TObject);
var
  LFiltro: string;
begin
  if lbSubs.ItemIndex >= 0 then
    LFiltro := lbSubs.Items[lbSubs.ItemIndex]
  else
    LFiltro := Trim(edFiltro.Text);
  FClient.Unsubscribe(LFiltro);
  Log('cancelei "' + LFiltro + '"');
  AtualizarListaDeAssinaturas;
end;

procedure TfrmMonitor.btnPublicarClick(Sender: TObject);
begin
  try
    if Hospedando then
      // O servidor publica direto: nao passa por RelayClientPublish, que so'
      // governa o que os CLIENTES publicam.
      FServer.PublishText(Trim(edTopico.Text), edTexto.Text, chkReter.Checked)
    else
      // No cliente, 'reter' e' um PEDIDO: so' e' atendido se o hospedeiro
      // estiver com RelayClientPublish ligado (sem relay, o servidor nao aceita
      // nada que o cliente publique, nem para os outros nem para o cache).
      FClient.PublishText(Trim(edTopico.Text), edTexto.Text);
  except
    on E: EPipeError do
      Log('nao publiquei: ' + E.Message);
  end;
end;

procedure TfrmMonitor.btnLimparClick(Sender: TObject);
begin
  lbRecebidas.Items.Clear;
end;

procedure TfrmMonitor.btnAplicarMaxClick(Sender: TObject);
begin
  FServer.MaxSubscriptionsPerClient := StrToIntDef(edMax.Text,
    PIPES_DEFAULT_MAX_SUBSCRIPTIONS);
  Log(Format('MaxSubscriptionsPerClient = %d (vale para as PROXIMAS ' +
    'assinaturas; as ja aceitas ficam)',
    [FServer.MaxSubscriptionsPerClient]));
end;

procedure TfrmMonitor.chkRelayClick(Sender: TObject);
begin
  // Property sem EnsureInactive de proposito: pode virar com o servidor no ar,
  // e e' esse o experimento que este sample existe para permitir.
  if Hospedando then
  begin
    FServer.RelayClientPublish := chkRelay.Checked;
    Log('RelayClientPublish = ' + BoolToStr(chkRelay.Checked, True));
  end;
end;

procedure TfrmMonitor.tmrRefreshTimer(Sender: TObject);
begin
  if not Hospedando then
    Exit;
  // SubscriberCount responde "quem receberia uma publicacao NESTE topico" —
  // com curinga do outro lado, e a unica forma honesta de saber.
  lblSrvInfo.Caption := Format('clientes: %d    assinantes de "%s": %d',
    [FServer.ClientCount, Trim(edTopico.Text),
     FServer.SubscriberCount(Trim(edTopico.Text))]);
end;

procedure TfrmMonitor.FormDestroy(Sender: TObject);
begin
  tmrRefresh.Enabled := False;
  FreeAndNil(FServer);
  FreeAndNil(FClient);
end;

end.
