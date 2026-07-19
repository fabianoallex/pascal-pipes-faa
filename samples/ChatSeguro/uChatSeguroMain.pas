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
  SysUtils, Classes, Generics.Collections,
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
    // Nome de cada conexao, guardado na ENTRADA. Necessario porque na saida a
    // identidade ja nao existe: quando OnClientDisconnected dispara, a conexao
    // ja saiu do registro do servidor e TryClientIdentity devolve False. Uma
    // aplicacao que queira dizer "loja-001 saiu" precisa ter anotado antes —
    // e' o padrao que este sample mostra.
    FNomes: TDictionary<TPipeConnectionId, string>;
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
  FNomes := TDictionary<TPipeConnectionId, string>.Create;
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
var
  LNome: string;
begin
  LNome := NomeDe(AConnId);
  FNomes.AddOrSetValue(AConnId, LNome); // anota para poder nomear a SAIDA
  Log(LNome + ' entrou.');
  AtualizaSala;
end;

procedure TfrmChatSeguro.SrvDisconnected(Sender: TObject;
  AConnId: TPipeConnectionId);
var
  LNome: string;
begin
  // NAO da' para perguntar a identidade aqui: quando este evento dispara a
  // conexao ja saiu do registro do servidor, e TryClientIdentity devolve
  // False. Por isso o nome vem do que foi anotado na entrada.
  if not FNomes.TryGetValue(AConnId, LNome) then
    LNome := 'conexao ' + IntToStr(AConnId);
  FNomes.Remove(AConnId);
  Log(LNome + ' saiu.');
  AtualizaSala;
end;

{ --- papel de participante (cliente) --- }

procedure TfrmChatSeguro.btnEntrarClick(Sender: TObject);
var
  LQuem: string;
begin
  LQuem := cbxIdentidade.Text;
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
  // A CA de teste nao esta no trust store da maquina; no OpenSSL isto basta
  // para validar o hub. (No Schannel o cliente valida contra o store do SO —
  // ver a tabela de diferencas entre backends no README.)
  FClient.TlsOptions.CaFile := Pki('ca_cert.pem');
  {$IFDEF PIPES_SCHANNEL}
  FClient.TlsOptions.SkipServerVerification := True; // so por ser PKI de teste
  {$ENDIF}
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
  Log('conectado ao hub (handshake TLS concluido).');
  lblStatus.Caption := 'conectado como "' + cbxIdentidade.Text + '" (mTLS)';
end;

procedure TfrmChatSeguro.CliDisconnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
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
  FNomes.Clear;        // sala vazia: os nomes anotados nao valem mais
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
  // Depois dos Free acima: os handlers ainda podiam tocar FNomes ate' aqui.
  FreeAndNil(FNomes);
end;

end.
