unit uEchoAndroidMain;

{ Tela unica do sample: endereco, chave de TLS, conectar/desconectar, campo de
  mensagem e log.

  Tres decisoes que valem para qualquer app FMX que use a lib:

  - DispatchMode := pdmMainThread. Os eventos (OnMessage/OnConnected/OnError)
    chegam pela thread principal via TThread.Queue, entao da' para mexer na UI
    direto do handler. Com o padrao (pdmPool) qualquer toque em componente
    visual dentro do evento seria acesso a UI de thread de pool.

  - Connect roda em thread propria (TConnectThread). Ele bloqueia ate' conectar
    ou estourar o prazo, e segurar a thread principal por segundos num celular
    faz o Android exibir o dialogo de "app nao responde". A thread carrega o
    resultado num CAMPO e o devolve pela UI com Synchronize — mesmo padrao dos
    work items da lib, sem closure (ver CLAUDE.md, restricoes de codigo).

  - Nada de ptLocal. No Android ele nao existe e a lib recusa com mensagem
    propria; o transporte aqui e' sempre ptTcp ou ptTls. }

interface

uses
  System.SysUtils,
  System.Classes,
  System.UITypes,
  FMX.Types,
  FMX.Controls,
  FMX.Forms,
  FMX.StdCtrls,
  FMX.Edit,
  FMX.Memo,
  FMX.Memo.Types,
  FMX.Layouts,
  FMX.Controls.Presentation,
  FMX.ScrollBox,
  Pipes.Types,
  Pipes.Client;

type
  TfrmEchoAndroid = class(TForm)
    lblEndereco: TLabel;
    edtEndereco: TEdit;
    lytTls: TLayout;
    lblTls: TLabel;
    swTls: TSwitch;
    lytBotoes: TLayout;
    btnConectar: TButton;
    btnDesconectar: TButton;
    edtMensagem: TEdit;
    btnEnviar: TButton;
    memLog: TMemo;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure btnConectarClick(Sender: TObject);
    procedure btnDesconectarClick(Sender: TObject);
    procedure btnEnviarClick(Sender: TObject);
  private
    FClient: TPipeClient;
    FConnecting: Boolean;
    procedure Log(const AText: string);
    procedure AtualizaBotoes;
    /// Chamado pela TConnectThread ao terminar (ja na thread principal).
    procedure ConexaoTerminou(const AError: string);
    // Eventos da lib (chegam na thread principal por causa de pdmMainThread).
    procedure ClienteConectado(Sender: TObject; AConnId: TPipeConnectionId);
    procedure ClienteDesconectado(Sender: TObject; AConnId: TPipeConnectionId);
    procedure ClienteMensagem(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure ClienteErro(Sender: TObject; AConnId: TPipeConnectionId;
      const AError: string);
  end;

var
  frmEchoAndroid: TfrmEchoAndroid;

implementation

{$R *.fmx}

type
  { Tira o Connect (bloqueante) da thread da UI. FreeOnTerminate: ninguem
    espera por ela — o resultado volta por Synchronize. }
  TConnectThread = class(TThread)
  private
    FForm: TfrmEchoAndroid;
    FClient: TPipeClient;
    FError: string;   // preenchido na thread, lido no Synchronize
    procedure Concluiu;
  protected
    procedure Execute; override;
  public
    constructor Create(AForm: TfrmEchoAndroid; AClient: TPipeClient);
  end;

constructor TConnectThread.Create(AForm: TfrmEchoAndroid;
  AClient: TPipeClient);
begin
  inherited Create(True);
  FreeOnTerminate := True;
  FForm := AForm;
  FClient := AClient;
end;

procedure TConnectThread.Execute;
begin
  FError := '';
  try
    FClient.Connect(8000);
  except
    on E: Exception do
      FError := E.ClassName + ': ' + E.Message;
  end;
  Synchronize(Concluiu);
end;

procedure TConnectThread.Concluiu;
begin
  FForm.ConexaoTerminou(FError);
end;

{ TfrmEchoAndroid }

procedure TfrmEchoAndroid.FormCreate(Sender: TObject);
begin
  FClient := TPipeClient.Create('');
  // Eventos na thread principal: o handler pode mexer na UI sem Synchronize.
  FClient.DispatchMode := pdmMainThread;
  // Rede movel cai e volta o tempo todo; deixar a lib reconectar sozinha e' o
  // comportamento util por padrao aqui.
  FClient.AutoReconnect := True;
  // Wi-Fi que dorme e NAT de operadora derrubam conexao ociosa em silencio.
  // O heartbeat de aplicacao detecta o zumbi nos dois sentidos.
  FClient.HeartbeatIntervalMs := 15000;
  FClient.KeepAliveSeconds := 30;
  FClient.OnConnected := ClienteConectado;
  FClient.OnDisconnected := ClienteDesconectado;
  FClient.OnMessage := ClienteMensagem;
  FClient.OnError := ClienteErro;
  Log('pronto. informe host:porta do EchoServer e toque em Conectar.');
  AtualizaBotoes;
end;

procedure TfrmEchoAndroid.FormDestroy(Sender: TObject);
begin
  // O destructor e' idempotente e ja faz Disconnect + join das threads.
  FreeAndNil(FClient);
end;

procedure TfrmEchoAndroid.Log(const AText: string);
begin
  memLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + AText);
  memLog.GoToTextEnd;
end;

procedure TfrmEchoAndroid.AtualizaBotoes;
var
  LConectado: Boolean;
begin
  LConectado := (FClient <> nil) and FClient.Connected;
  btnConectar.Enabled := not LConectado and not FConnecting;
  btnDesconectar.Enabled := LConectado or FConnecting;
  btnEnviar.Enabled := LConectado;
  edtEndereco.Enabled := not LConectado and not FConnecting;
  swTls.Enabled := not LConectado and not FConnecting;
end;

procedure TfrmEchoAndroid.btnConectarClick(Sender: TObject);
var
  LEndereco: string;
begin
  LEndereco := Trim(edtEndereco.Text);
  if LEndereco = '' then
  begin
    Log('informe o endereco no formato host:porta.');
    Exit;
  end;

  FClient.Address := LEndereco;
  if swTls.IsChecked then
  begin
    FClient.Transport := ptTls;
    // CaFile vazio = valida contra o trust store do sistema (no Android a lib
    // aponta sozinha para /system/etc/security/cacerts — o default do OpenSSL
    // nao serve la). Com PKI propria, que e' o caso tipico de frota, aponte
    // para o PEM da sua CA, copiado para a pasta de documentos do app pelo
    // Deployment do projeto:
    //   FClient.TlsOptions.CaFile :=
    //     TPath.Combine(TPath.GetDocumentsPath, 'ca.pem');
    Log('conectando a ' + LEndereco + ' (ptTls)...');
  end
  else
  begin
    FClient.Transport := ptTcp;
    Log('conectando a ' + LEndereco + ' (ptTcp)...');
  end;

  FConnecting := True;
  AtualizaBotoes;
  TConnectThread.Create(Self, FClient).Start;
end;

procedure TfrmEchoAndroid.ConexaoTerminou(const AError: string);
begin
  FConnecting := False;
  if AError <> '' then
    Log('falha ao conectar - ' + AError);
  AtualizaBotoes;
end;

procedure TfrmEchoAndroid.btnDesconectarClick(Sender: TObject);
begin
  // Disconnect nao demora: o CloseAbort do backend Android acorda a reader
  // thread pelo self-pipe em milissegundos, mesmo com a conexao ociosa.
  // AutoReconnect precisa sair do caminho, senao a lib reconecta em seguida.
  FClient.AutoReconnect := False;
  try
    FClient.Disconnect;
  finally
    FClient.AutoReconnect := True;
  end;
  Log('desconectado.');
  AtualizaBotoes;
end;

procedure TfrmEchoAndroid.btnEnviarClick(Sender: TObject);
var
  LTexto: string;
begin
  LTexto := edtMensagem.Text;
  if LTexto = '' then
    Exit;
  try
    FClient.SendText(LTexto);
    Log('-> ' + LTexto);
    edtMensagem.Text := '';
  except
    on E: Exception do
      Log('falha ao enviar - ' + E.Message);
  end;
end;

procedure TfrmEchoAndroid.ClienteConectado(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  Log('conectado a ' + FClient.ActiveAddress);
  AtualizaBotoes;
end;

procedure TfrmEchoAndroid.ClienteDesconectado(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  Log('conexao caiu.');
  AtualizaBotoes;
end;

procedure TfrmEchoAndroid.ClienteMensagem(Sender: TObject;
  AConnId: TPipeConnectionId; const AData: TBytes);
begin
  Log('<- ' + TEncoding.UTF8.GetString(AData));
end;

procedure TfrmEchoAndroid.ClienteErro(Sender: TObject;
  AConnId: TPipeConnectionId; const AError: string);
begin
  Log('erro: ' + AError);
end;

end.
