unit uChatMain;

{ Chat via Named Pipes numa tela so: o mesmo executavel pode ser o servidor
  (hub que retransmite tudo que recebe via Broadcast) ou um cliente. Abra uma
  instancia como servidor e varias como cliente, no mesmo nome de pipe.

  O ponto da vitrine e' o DispatchMode = pdmMainThread: os handlers abaixo
  mexem em Memo/Label DIRETO, sem Synchronize/Queue manual — a lib ja entrega
  os eventos na thread da UI (e descarta com seguranca os que chegarem depois
  do Free, via objeto-guarda).

  Compila nos dois mundos a partir do MESMO fonte (dfm para o Delphi/VCL,
  lfm para o Lazarus/LCL). }

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
  SysUtils, Classes,
  Graphics, Controls, Forms, Dialogs, StdCtrls,
  Pipes.Types, Pipes.Framing, Pipes.Server, Pipes.Client;

type
  TfrmChat = class(TForm)
    lblPipe: TLabel;
    edtPipeName: TEdit;
    btnServidor: TButton;
    btnCliente: TButton;
    btnDesligar: TButton;
    lblStatus: TLabel;
    memoLog: TMemo;
    edtMensagem: TEdit;
    btnEnviar: TButton;
    procedure btnServidorClick(Sender: TObject);
    procedure btnClienteClick(Sender: TObject);
    procedure btnDesligarClick(Sender: TObject);
    procedure btnEnviarClick(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    FServer: TNamedPipeServer;
    FClient: TNamedPipeClient;
    procedure Log(const S: string);
    procedure SetUiLigada(ALigada: Boolean);
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
  frmChat: TfrmChat;

implementation

{$IFDEF FPC}
  {$R *.lfm}
{$ELSE}
  {$R *.dfm}
{$ENDIF}

procedure TfrmChat.Log(const S: string);
begin
  memoLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + S);
end;

procedure TfrmChat.SetUiLigada(ALigada: Boolean);
begin
  btnServidor.Enabled := not ALigada;
  btnCliente.Enabled := not ALigada;
  edtPipeName.Enabled := not ALigada;
  btnDesligar.Enabled := ALigada;
end;

{ --- papel de servidor --- }

procedure TfrmChat.btnServidorClick(Sender: TObject);
begin
  FServer := TNamedPipeServer.Create(edtPipeName.Text);
  FServer.DispatchMode := pdmMainThread; // eventos direto na thread da UI
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
  lblStatus.Caption := 'servidor escutando em "' + edtPipeName.Text + '"';
  Log('servidor no ar.');
  SetUiLigada(True);
end;

procedure TfrmChat.SrvMessage(Sender: TObject; AConnId: TPipeConnectionId;
  const AData: TBytes);
var
  LLinha: string;
begin
  // Hub de chat: retransmite a todos (inclusive quem mandou, que assim ve a
  // propria mensagem confirmada pelo servidor).
  LLinha := '[cliente ' + IntToStr(AConnId) + '] ' + PipeUtf8Decode(AData);
  Log(LLinha);
  FServer.BroadcastText(LLinha);
end;

procedure TfrmChat.SrvConnected(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log('cliente ' + IntToStr(AConnId) + ' entrou (' +
    IntToStr(FServer.ClientCount) + ' online)');
end;

procedure TfrmChat.SrvDisconnected(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log('cliente ' + IntToStr(AConnId) + ' saiu (' +
    IntToStr(FServer.ClientCount) + ' online)');
end;

{ --- papel de cliente --- }

procedure TfrmChat.btnClienteClick(Sender: TObject);
begin
  FClient := TNamedPipeClient.Create(edtPipeName.Text);
  FClient.DispatchMode := pdmMainThread; // eventos direto na thread da UI
  FClient.AutoReconnect := True;         // servidor reiniciou? volta sozinho
  FClient.OnMessage := CliMessage;
  FClient.OnConnected := CliConnected;
  FClient.OnDisconnected := CliDisconnected;
  FClient.OnError := AnyError;
  try
    FClient.Connect(3000); // blocante ate 3 s: aceitavel num clique de sample
  except
    FreeAndNil(FClient);
    raise;
  end;
  lblStatus.Caption := 'cliente conectado a "' + edtPipeName.Text + '"';
  SetUiLigada(True);
end;

procedure TfrmChat.CliMessage(Sender: TObject; AConnId: TPipeConnectionId;
  const AData: TBytes);
begin
  Log(PipeUtf8Decode(AData));
end;

procedure TfrmChat.CliConnected(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log('conectado ao servidor.');
  lblStatus.Caption := 'cliente conectado a "' + edtPipeName.Text + '"';
end;

procedure TfrmChat.CliDisconnected(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log('conexao caiu - AutoReconnect tentando...');
  lblStatus.Caption := 'reconectando...';
end;

{ --- comum --- }

procedure TfrmChat.AnyError(Sender: TObject; AConnId: TPipeConnectionId;
  const AError: string);
begin
  Log('erro: ' + AError);
end;

procedure TfrmChat.btnEnviarClick(Sender: TObject);
var
  LTexto: string;
begin
  LTexto := Trim(edtMensagem.Text);
  if LTexto = '' then
    Exit;
  try
    if FServer <> nil then
    begin
      // Servidor fala com todos direto.
      Log('[servidor] ' + LTexto);
      FServer.BroadcastText('[servidor] ' + LTexto);
    end
    else if FClient <> nil then
      // Cliente manda ao hub; a propria mensagem volta via broadcast.
      FClient.SendText(LTexto)
    else
      Log('inicie o servidor ou conecte como cliente primeiro.');
    edtMensagem.Text := '';
  except
    on E: EPipeError do
      Log('falha no envio: ' + E.Message);
  end;
end;

procedure TfrmChat.btnDesligarClick(Sender: TObject);
begin
  FreeAndNil(FClient); // Disconnect sincrono no destructor
  FreeAndNil(FServer); // Stop sincrono no destructor
  lblStatus.Caption := 'parado';
  Log('desligado.');
  SetUiLigada(False);
end;

procedure TfrmChat.FormDestroy(Sender: TObject);
begin
  // Eventos pdmMainThread que ainda estiverem na fila viram no-op depois
  // daqui (objeto-guarda da lib) — fechar a janela no meio do trafego e' seguro.
  FreeAndNil(FClient);
  FreeAndNil(FServer);
end;

end.
