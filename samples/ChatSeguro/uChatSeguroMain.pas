unit uChatSeguroMain;

{ Chat sobre ptTls com mTLS, numa tela so: a mesma instancia pode ser o hub
  (servidor) ou um participante (cliente).

  O que este sample mostra, e que o ChatVcl nao mostra:

  - QUEM esta na sala vem do CERTIFICADO, nao de um apelido digitado. O hub
    rotula cada mensagem com o CommonName que TryClientIdentity devolve. Num
    chat comum o participante escolhe como quer ser chamado e ninguem confere;
    aqui o nome e' o do certificado que ele apresentou e que o servidor validou
    contra a CA — quem nao tiver certificado dela nao entra.

  - A lista de participantes vem de ClientIds, que so lista conexoes
    ESTABELECIDAS: um par ainda negociando TLS (ou que sera' recusado) nunca
    aparece na tela.

  - pdmMainThread + AutoReconnect + TLS juntos: os handlers mexem na UI direto,
    e o cliente refaz o handshake sozinho quando o hub volta.

  Precisa da PKI de teste em tests/pki (o proprio form a localiza). Compila nos
  dois mundos a partir do MESMO fonte (dfm para Delphi/VCL, lfm para
  Lazarus/LCL). }

// pipes.inc e' quem define PIPES_SCHANNEL/PIPES_OPENSSL — sem ele os IFDEFs de
// backend abaixo nunca ativariam e o sample tentaria ler um PEM como PFX. Ele
// tambem ja liga {$MODE DELPHI}{$H+} no FPC, entao nao ha bloco de modo aqui.
{$I pipes.inc}

interface

uses
  {$IFDEF FPC}
  LCLIntf, LCLType,
  {$ELSE}
  Windows, Messages,
  {$ENDIF}
  SysUtils, Classes, DateUtils,
  Graphics, Controls, Forms, Dialogs, StdCtrls,
  Pipes.Types, Pipes.Framing, Pipes.Base, Pipes.Server, Pipes.Client;

type
  TfrmChatSeguro = class(TForm)
    lblEndereco: TLabel;
    edtEndereco: TEdit;
    lblIdentidade: TLabel;
    cbxIdentidade: TComboBox;
    btnHub: TButton;
    btnEntrar: TButton;
    btnDesligar: TButton;
    lblStatus: TLabel;
    memoLog: TMemo;
    lblSala: TLabel;
    lstSala: TListBox;
    edtMensagem: TEdit;
    btnEnviar: TButton;
    procedure btnHubClick(Sender: TObject);
    procedure btnEntrarClick(Sender: TObject);
    procedure btnDesligarClick(Sender: TObject);
    procedure btnEnviarClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    FServer: TPipeServer;
    FClient: TPipeClient;
    FPkiDir: string;

    // Instante do ultimo OnConnected do cliente. Serve para reconhecer a
    // recusa por certificado: ver CliDisconnected.
    FConectouEm: TDateTime;
    // Ja reconheceu a recusa nesta tentativa. Necessario porque desligar
    // AutoReconnect de dentro do callback NAO cancela o que ja esta em voo:
    // com pdmMainThread o evento e' enfileirado para a UI, entao a lib pode ja'
    // ter reconectado mais uma ou duas vezes antes de o handler rodar. Sem
    // esta flag a mensagem de recusa apareceria repetida, dando a impressao
    // errada de que desligar nao funcionou.
    FRecusado: Boolean;
    procedure Log(const S: string);
    procedure SetUiLigada(ALigada: Boolean);
    function Pki(const AFile: string): string;
    /// Nome pelo qual o hub conhece esta conexao: o CN do certificado
    /// validado. Cai para 'conexao N' fora do mTLS — e' o sample deixando
    /// visivel que sem certificado nao ha identidade.
    function NomeDe(AConnId: TPipeConnectionId): string;
    procedure AtualizaSala;
    // Handlers da lib — pdmMainThread: rodam na thread da UI.
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
  end;

var
  frmChatSeguro: TfrmChatSeguro;

implementation

{$IFDEF FPC}
  {$R *.lfm}
{$ELSE}
  {$R *.dfm}
{$ENDIF}

procedure TfrmChatSeguro.Log(const S: string);
begin
  memoLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + S);
end;

procedure TfrmChatSeguro.FormCreate(Sender: TObject);
var
  LDir: string;
  I: Integer;
begin
  // Localiza tests/pki subindo a partir do executavel: o sample roda de
  // samples\ChatSeguro\Win64\Debug ou de samples/ChatSeguro no Lazarus.
  FPkiDir := '';
  LDir := ExtractFilePath(ParamStr(0));
  for I := 0 to 6 do
  begin
    if FileExists(LDir + 'tests' + PathDelim + 'pki' + PathDelim +
         'ca_cert.pem') then
    begin
      FPkiDir := LDir + 'tests' + PathDelim + 'pki' + PathDelim;
      Break;
    end;
    LDir := LDir + '..' + PathDelim;
  end;
  if FPkiDir = '' then
    Log('ATENCAO: tests/pki nao encontrada — sem ela nao ha certificados e ' +
      'nada aqui vai conectar.')
  else
    Log('PKI de teste: ' + FPkiDir);
end;

function TfrmChatSeguro.Pki(const AFile: string): string;
begin
  Result := FPkiDir + AFile;
end;

procedure TfrmChatSeguro.SetUiLigada(ALigada: Boolean);
begin
  btnHub.Enabled := not ALigada;
  btnEntrar.Enabled := not ALigada;
  edtEndereco.Enabled := not ALigada;
  cbxIdentidade.Enabled := not ALigada;
  btnDesligar.Enabled := ALigada;
end;

{ --- papel de hub (servidor) --- }

procedure TfrmChatSeguro.btnHubClick(Sender: TObject);
begin
  FServer := TPipeServer.Create(edtEndereco.Text, ptTls);
  FServer.DispatchMode := pdmMainThread; // eventos direto na thread da UI
  // Credenciais do hub. CaFile LIGA mTLS: so entra quem apresentar
  // certificado assinado por esta CA.
  {$IFDEF PIPES_SCHANNEL}
  FServer.TlsOptions.CertFile := Pki('srv.pfx');
  FServer.TlsOptions.CertPassword := 'pipestest';
  {$ELSE}
  FServer.TlsOptions.CertFile := Pki('srv_cert.pem');
  FServer.TlsOptions.KeyFile := Pki('srv_key.pem');
  {$ENDIF}
  FServer.TlsOptions.CaFile := Pki('ca_cert.pem');
  FServer.OnMessage := SrvMessage;
  FServer.OnClientConnected := SrvConnected;
  FServer.OnClientDisconnected := SrvDisconnected;
  FServer.OnError := AnyError;
  try
    FServer.Listen;
  except
    FreeAndNil(FServer);
    raise;
  end;
  lblStatus.Caption := 'hub escutando em ' + edtEndereco.Text + ' (mTLS)';
  Log('hub no ar; so entra quem tiver certificado da CA de teste.');
  SetUiLigada(True);
  AtualizaSala;
end;

function TfrmChatSeguro.NomeDe(AConnId: TPipeConnectionId): string;
var
  LQuem: TPipePeerIdentity;
begin
  // A identidade vem do certificado que o servidor JA validou no handshake.
  // Um CN forjado nao chega aqui: seria recusado antes de OnClientConnected.
  if (FServer <> nil) and FServer.TryClientIdentity(AConnId, LQuem) and
     (LQuem.CommonName <> '') then
    Result := LQuem.CommonName
  else
    // Sem mTLS nao ha identidade nenhuma — e o sample mostra isso em vez de
    // inventar um nome.
    Result := 'conexao ' + IntToStr(AConnId) + ' (sem certificado)';
end;

procedure TfrmChatSeguro.AtualizaSala;
var
  LIds: TArray<TPipeConnectionId>;
  I: Integer;
begin
  lstSala.Items.BeginUpdate;
  try
    lstSala.Items.Clear;
    if FServer = nil then
      Exit;
    // ClientIds lista SO conexoes estabelecidas: quem ainda esta negociando
    // TLS (ou vai ser recusado) nunca aparece na sala.
    LIds := FServer.ClientIds;
    for I := 0 to High(LIds) do
      lstSala.Items.Add(NomeDe(LIds[I]));
  finally
    lstSala.Items.EndUpdate;
  end;
  lblSala.Caption := 'Na sala (' + IntToStr(lstSala.Items.Count) + '):';
end;

procedure TfrmChatSeguro.SrvMessage(Sender: TObject;
  AConnId: TPipeConnectionId; const AData: TBytes);
var
  LLinha: string;
begin
  // O rotulo e' o nome do CERTIFICADO, nao algo que o cliente mandou: ele nao
  // tem como se passar por outro participante.
  LLinha := '[' + NomeDe(AConnId) + '] ' + PipeUtf8Decode(AData);
  Log(LLinha);
  FServer.BroadcastText(LLinha);
end;

procedure TfrmChatSeguro.SrvConnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  Log(NomeDe(AConnId) + ' entrou.');
  AtualizaSala;
end;

procedure TfrmChatSeguro.SrvDisconnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  // A identidade sobrevive a saida da conexao de proposito (ver
  // TryClientIdentity), entao da' para nomear quem saiu sem a aplicacao
  // precisar manter um cache proprio.
  Log(NomeDe(AConnId) + ' saiu.');
  AtualizaSala;
end;

{ --- papel de participante (cliente) --- }

procedure TfrmChatSeguro.btnEntrarClick(Sender: TObject);
var
  LQuem: string;
begin
  LQuem := cbxIdentidade.Text;
  FConectouEm := 0;   // tentativa nova: nao herda o instante da anterior
  FRecusado := False; // idem para o reconhecimento de recusa
  FClient := TPipeClient.Create(edtEndereco.Text, ptTls);
  FClient.DispatchMode := pdmMainThread;
  FClient.AutoReconnect := True; // hub reiniciou? refaz o handshake sozinho
  // O certificado escolhido e' a identidade: trocar o combo troca quem voce e'
  // aos olhos do hub. 'rogue' e 'selfsigned' existem para ver a RECUSA.
  {$IFDEF PIPES_SCHANNEL}
  FClient.TlsOptions.CertFile := Pki(LQuem + '.pfx');
  FClient.TlsOptions.CertPassword := 'pipestest';
  {$ELSE}
  FClient.TlsOptions.CertFile := Pki(LQuem + '_cert.pem');
  FClient.TlsOptions.KeyFile := Pki(LQuem + '_key.pem');
  {$ENDIF}
  // A CA de teste nao esta no trust store da maquina; CaFile basta para
  // validar o hub, nos dois backends desde a 0.4.0.
  FClient.TlsOptions.CaFile := Pki('ca_cert.pem');
  FClient.OnMessage := CliMessage;
  FClient.OnConnected := CliConnected;
  FClient.OnDisconnected := CliDisconnected;
  FClient.OnError := AnyError;
  try
    FClient.Connect(3000); // blocante ate 3 s: aceitavel num clique de sample
  except
    on E: Exception do
    begin
      FreeAndNil(FClient);
      // Recusa de certificado cai AQUI — e' o caminho que 'rogue' exercita.
      Log('nao entrou: ' + E.ClassName + ': ' + E.Message);
      Exit;
    end;
  end;
  lblStatus.Caption := 'conectado como "' + LQuem + '" (mTLS)';
  SetUiLigada(True);
end;

procedure TfrmChatSeguro.CliMessage(Sender: TObject;
  AConnId: TPipeConnectionId; const AData: TBytes);
begin
  Log(PipeUtf8Decode(AData));
end;

procedure TfrmChatSeguro.CliConnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  FConectouEm := Now;
  // A lib descarta a sessao se AutoReconnect virar False durante o PipeConnect,
  // mas nada elimina a janela: uma tentativa pode concluir no exato instante da
  // decisao. Anunciar "conectado" depois da recusa confundiria — entao aqui a
  // sessao residual e' nomeada pelo que ela e'.
  if FRecusado then
  begin
    Log('(conexao residual de uma tentativa que ja estava em voo; ' +
      'o hub vai derruba-la)');
    Exit;
  end;
  // ATENCAO ao ler isto no backend SCHANNEL: "handshake concluido" aqui NAO
  // significa "fui aceito". O servidor Schannel completa o handshake e so'
  // ENTAO valida a cadeia do certificado, entao um cliente recusado passa por
  // este evento e leva a queda logo depois. E' o que CliDisconnected trata.
  Log('conectado ao hub (handshake TLS concluido).');
  lblStatus.Caption := 'conectado como "' + cbxIdentidade.Text + '" (mTLS)';
end;

procedure TfrmChatSeguro.CliDisconnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  // Sessao que morre quase junto com o OnConnected e' recusa de credencial,
  // nao queda de rede: o hub aceitou o handshake e derrubou ao reprovar o
  // certificado. Isso NAO se conserta sozinho — insistir seria martelar o
  // servidor com uma credencial que ele acabou de rejeitar.
  if FRecusado or
     ((FConectouEm > 0) and (MilliSecondsBetween(Now, FConectouEm) < 1000)) then
  begin
    FClient.AutoReconnect := False;
    if not FRecusado then
    begin
      FRecusado := True;
      Log('RECUSADO pelo hub: o certificado "' + cbxIdentidade.Text +
        '" nao foi aceito. Reconexao desligada (nao adianta insistir).');
      lblStatus.Caption := 'recusado - troque a identidade e tente de novo';
    end;
    Exit;
  end;
  Log('conexao caiu - AutoReconnect vai refazer o handshake...');
  lblStatus.Caption := 'reconectando...';
end;

{ --- comum --- }

procedure TfrmChatSeguro.AnyError(Sender: TObject;
  AConnId: TPipeConnectionId; const AError: string);
begin
  Log('erro: ' + AError);
  // Handshake recusado aparece aqui, do lado do hub: e' o que se ve ao tentar
  // entrar com o certificado 'rogue'.
  if FServer <> nil then
    AtualizaSala;
end;

procedure TfrmChatSeguro.btnEnviarClick(Sender: TObject);
var
  LTexto: string;
begin
  LTexto := Trim(edtMensagem.Text);
  if LTexto = '' then
    Exit;
  try
    if FServer <> nil then
    begin
      Log('[hub] ' + LTexto);
      FServer.BroadcastText('[hub] ' + LTexto);
    end
    else if FClient <> nil then
      FClient.SendText(LTexto)
    else
      Log('suba o hub ou entre como participante primeiro.');
    edtMensagem.Text := '';
  except
    on E: EPipeError do
      Log('falha no envio: ' + E.Message);
  end;
end;

procedure TfrmChatSeguro.btnDesligarClick(Sender: TObject);
begin
  FreeAndNil(FClient); // Disconnect sincrono no destructor
  FreeAndNil(FServer); // Stop sincrono no destructor
  lblStatus.Caption := 'parado';
  Log('desligado.');
  SetUiLigada(False);
  AtualizaSala;
end;

procedure TfrmChatSeguro.FormDestroy(Sender: TObject);
begin
  // Eventos pdmMainThread ainda na fila viram no-op depois daqui (objeto-guarda
  // da lib): fechar a janela no meio do trafego e' seguro.
  FreeAndNil(FClient);
  FreeAndNil(FServer);
end;

end.
