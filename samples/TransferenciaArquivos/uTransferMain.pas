unit uTransferMain;

{ Transferencia de arquivos numa tela so: o mesmo executavel pode ser o
  servidor (recebe e salva em "recebidos\") ou um cliente (escolhe um
  arquivo e manda). Abra uma instancia como servidor e outra como cliente,
  no mesmo nome de pipe.

  Vitrine de CompressionMinSize e dos campos Wire de Stats (Pipes.Compression,
  Pipes.Types — ver docs/ARQUITETURA.md §17): o checkbox "Comprimir" so' pode
  mudar com o cliente DESCONECTADO (mesma regra de MaxMessageSize), e fica
  travado depois de conectar. Cada envio loga a economia de banda dos dois
  lados — do cliente via Client.Stats (BytesSent/BytesSentWire, delta antes/
  depois do SendBytes) e do servidor via ConnectionStats.BytesReceivedWire,
  que e' a UNICA forma de o lado que so' recebe enxergar a economia: a
  descompressao ja devolve o payload logico antes de OnMessage rodar, de
  proposito (nao ha' como saber, so' de olhar os bytes recebidos, se aquele
  frame especifico veio comprimido).

  Protocolo do payload (so' deste sample, nao da lib): envelope simples
  [TamanhoDoNome:4 bytes LE][NomeUTF8][BytesDoArquivo] — nenhum sample ainda
  transportava binario, entao nao ha' um formato pronto para reaproveitar
  (Pipes.Json seria overkill para isto). Arquivo inteiro em memoria, um
  SendBytes so' — sem chunking/streaming/retomada: serve para demonstrar a
  feature, nao e' um protocolo de transferencia de producao.

  Compila nos dois mundos a partir do MESMO fonte (dfm para o Delphi/VCL,
  lfm para o Lazarus/LCL), mesmo molde do ChatVcl. }

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
  TfrmTransfer = class(TForm)
    lblPipe: TLabel;
    edtPipeName: TEdit;
    btnServidor: TButton;
    btnCliente: TButton;
    btnDesligar: TButton;
    chkComprimir: TCheckBox;
    lblStatus: TLabel;
    edtArquivo: TEdit;
    btnEscolherArquivo: TButton;
    btnEnviar: TButton;
    memoLog: TMemo;
    OpenDialog1: TOpenDialog;
    procedure btnServidorClick(Sender: TObject);
    procedure btnClienteClick(Sender: TObject);
    procedure btnDesligarClick(Sender: TObject);
    procedure btnEscolherArquivoClick(Sender: TObject);
    procedure btnEnviarClick(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    FServer: TNamedPipeServer;
    FClient: TNamedPipeClient;
    FArquivoSelecionado: string;
    procedure Log(const S: string);
    procedure SetUiLigada(ALigada: Boolean);
    procedure UpdateClientControls;
    // Handlers da lib — pdmMainThread: rodam na thread da UI.
    procedure SrvFileReceived(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure SrvConnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure SrvDisconnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure CliConnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure CliDisconnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure AnyError(Sender: TObject; AConnId: TPipeConnectionId;
      const AError: string);
  end;

var
  frmTransfer: TfrmTransfer;

implementation

{$IFDEF FPC}
  {$R *.lfm}
{$ELSE}
  {$R *.dfm}
{$ENDIF}

const
  // Folga generosa acima do default (16 MB) para arquivos de demo maiores
  // (fotos, PDFs). Arquivo inteiro em memoria — nao e' streaming.
  TAMANHO_MAX_ARQUIVO = 64 * 1024 * 1024;
  // So' tenta comprimir payload >= 512 bytes (ver docs/ARQUITETURA.md §17,
  // valor recomendado quando CompressionMinSize esta' ligado).
  COMPRESSION_MIN_SIZE = 512;

{ --- envelope [TamanhoDoNome:4][NomeUTF8][BytesDoArquivo] (so' deste sample) --- }

function EncodeFileEnvelope(const AFileName: string;
  const AFileBytes: TBytes): TBytes;
var
  LNameBytes: TBytes;
  LNameLen: Cardinal;
begin
  LNameBytes := PipeUtf8Encode(AFileName);
  LNameLen := Cardinal(Length(LNameBytes));
  Result := nil;
  SetLength(Result, 4 + Length(LNameBytes) + Length(AFileBytes));
  Result[0] := Byte(LNameLen);
  Result[1] := Byte(LNameLen shr 8);
  Result[2] := Byte(LNameLen shr 16);
  Result[3] := Byte(LNameLen shr 24);
  if Length(LNameBytes) > 0 then
    Move(LNameBytes[0], Result[4], Length(LNameBytes));
  if Length(AFileBytes) > 0 then
    Move(AFileBytes[0], Result[4 + Length(LNameBytes)], Length(AFileBytes));
end;

procedure DecodeFileEnvelope(const AEnvelope: TBytes; out AFileName: string;
  out AFileBytes: TBytes);
var
  LNameLen: Cardinal;
  LNameBytes: TBytes;
begin
  if Length(AEnvelope) < 4 then
    raise Exception.Create('envelope de arquivo invalido (menor que o cabecalho)');
  LNameLen := Cardinal(AEnvelope[0]) or (Cardinal(AEnvelope[1]) shl 8) or
    (Cardinal(AEnvelope[2]) shl 16) or (Cardinal(AEnvelope[3]) shl 24);
  if UInt64(Length(AEnvelope)) < UInt64(4) + LNameLen then
    raise Exception.Create('envelope de arquivo invalido (nome maior que o payload)');
  LNameBytes := nil;
  SetLength(LNameBytes, LNameLen);
  if LNameLen > 0 then
    Move(AEnvelope[4], LNameBytes[0], LNameLen);
  AFileName := PipeUtf8Decode(LNameBytes);
  AFileBytes := nil;
  SetLength(AFileBytes, Length(AEnvelope) - 4 - Integer(LNameLen));
  if Length(AFileBytes) > 0 then
    Move(AEnvelope[4 + Integer(LNameLen)], AFileBytes[0], Length(AFileBytes));
end;

// Nunca sobrescreve: acrescenta " (1)", " (2)"... se o nome ja existir na
// pasta de destino (varios envios de teste com o mesmo arquivo nao se apagam).
function UniqueDestPath(const ADir, AFileName: string): string;
var
  LBase, LExt, LCandidate: string;
  I: Integer;
begin
  LExt := ExtractFileExt(AFileName);
  LBase := ChangeFileExt(AFileName, '');
  LCandidate := IncludeTrailingPathDelimiter(ADir) + AFileName;
  I := 1;
  while FileExists(LCandidate) do
  begin
    LCandidate := IncludeTrailingPathDelimiter(ADir) + LBase + ' (' +
      IntToStr(I) + ')' + LExt;
    Inc(I);
  end;
  Result := LCandidate;
end;

function PercentSaved(ALogical, AWire: UInt64): string;
begin
  if ALogical = 0 then
    Exit('0,0%');
  Result := FormatFloat('0.0', (1 - (AWire / ALogical)) * 100) + '%';
end;

{ TfrmTransfer }

procedure TfrmTransfer.Log(const S: string);
begin
  memoLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + S);
end;

procedure TfrmTransfer.SetUiLigada(ALigada: Boolean);
begin
  btnServidor.Enabled := not ALigada;
  btnCliente.Enabled := not ALigada;
  edtPipeName.Enabled := not ALigada;
  // CompressionMinSize so' muda com o componente inativo (EnsureInactive) —
  // o checkbox reflete essa regra travando junto.
  chkComprimir.Enabled := not ALigada;
  btnDesligar.Enabled := ALigada;
  UpdateClientControls;
end;

procedure TfrmTransfer.UpdateClientControls;
begin
  btnEscolherArquivo.Enabled := FClient <> nil;
  btnEnviar.Enabled := (FClient <> nil) and (FArquivoSelecionado <> '');
end;

{ --- papel de servidor --- }

procedure TfrmTransfer.btnServidorClick(Sender: TObject);
begin
  FServer := TNamedPipeServer.Create(edtPipeName.Text);
  FServer.DispatchMode := pdmMainThread; // eventos direto na thread da UI
  FServer.MaxMessageSize := TAMANHO_MAX_ARQUIVO;
  FServer.OnMessage := SrvFileReceived;
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
  Log('servidor no ar. Arquivos recebidos vao para a pasta "recebidos".');
  SetUiLigada(True);
end;

procedure TfrmTransfer.SrvFileReceived(Sender: TObject;
  AConnId: TPipeConnectionId; const AData: TBytes);
var
  LFileName, LSafeName, LPastaDestino, LDestPath: string;
  LFileBytes: TBytes;
  LStream: TFileStream;
  LConnStats: TPipeConnStats;
begin
  try
    DecodeFileEnvelope(AData, LFileName, LFileBytes);
  except
    on E: Exception do
    begin
      Log('envelope de arquivo invalido do cliente ' + IntToStr(AConnId) +
        ': ' + E.Message);
      Exit;
    end;
  end;

  // ExtractFileName descarta qualquer caminho que o remetente tenha mandado
  // — nunca confiar no nome recebido para montar um caminho de escrita.
  LSafeName := ExtractFileName(LFileName);
  if LSafeName = '' then
    LSafeName := 'arquivo_recebido';
  LPastaDestino := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) +
    'recebidos';
  ForceDirectories(LPastaDestino);
  LDestPath := UniqueDestPath(LPastaDestino, LSafeName);

  LStream := TFileStream.Create(LDestPath, fmCreate);
  try
    if Length(LFileBytes) > 0 then
      LStream.WriteBuffer(LFileBytes[0], Length(LFileBytes));
  finally
    LStream.Free;
  end;

  Log(Format('recebido do cliente %d: "%s" (%d bytes) salvo em %s',
    [AConnId, LSafeName, Length(LFileBytes), ExtractFileName(LDestPath)]));

  // BytesReceivedWire e' a UNICA forma de o servidor enxergar a economia da
  // compressao (ver cabecalho da unit) — cumulativo DESTA CONEXAO desde que
  // abriu, nao so' deste arquivo.
  if FServer.ConnectionStats(AConnId, LConnStats) then
    Log(Format(
      '  conexao %d ate agora: %d bytes logicos recebidos, %d no fio (economia acumulada: %s)',
      [AConnId, LConnStats.BytesReceived, LConnStats.BytesReceivedWire,
       PercentSaved(LConnStats.BytesReceived, LConnStats.BytesReceivedWire)]));
end;

procedure TfrmTransfer.SrvConnected(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log('cliente ' + IntToStr(AConnId) + ' conectou (' +
    IntToStr(FServer.ClientCount) + ' online)');
end;

procedure TfrmTransfer.SrvDisconnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  Log('cliente ' + IntToStr(AConnId) + ' saiu (' +
    IntToStr(FServer.ClientCount) + ' online)');
end;

{ --- papel de cliente --- }

procedure TfrmTransfer.btnClienteClick(Sender: TObject);
var
  LComprimir: string;
begin
  FClient := TNamedPipeClient.Create(edtPipeName.Text);
  FClient.DispatchMode := pdmMainThread; // eventos direto na thread da UI
  FClient.MaxMessageSize := TAMANHO_MAX_ARQUIVO;
  if chkComprimir.Checked then
  begin
    FClient.CompressionMinSize := COMPRESSION_MIN_SIZE;
    LComprimir := 'ligada';
  end
  else
  begin
    FClient.CompressionMinSize := 0;
    LComprimir := 'desligada';
  end;
  FClient.OnConnected := CliConnected;
  FClient.OnDisconnected := CliDisconnected;
  FClient.OnError := AnyError;
  try
    FClient.Connect(3000); // blocante ate 3 s: aceitavel num clique de sample
  except
    FreeAndNil(FClient);
    raise;
  end;
  lblStatus.Caption := 'cliente conectado a "' + edtPipeName.Text +
    '" (compressao ' + LComprimir + ')';
  Log('conectado. compressao ' + LComprimir + '.');
  SetUiLigada(True);
end;

procedure TfrmTransfer.CliConnected(Sender: TObject; AConnId: TPipeConnectionId);
begin
  // Ja logado em btnClienteClick (Connect e' sincrono neste sample); aqui so'
  // cobre uma reconexao futura, se algum dia este sample ligar AutoReconnect.
end;

procedure TfrmTransfer.CliDisconnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  Log('conexao com o servidor caiu.');
  lblStatus.Caption := 'desconectado';
end;

procedure TfrmTransfer.btnEscolherArquivoClick(Sender: TObject);
begin
  if OpenDialog1.Execute then
  begin
    FArquivoSelecionado := OpenDialog1.FileName;
    edtArquivo.Text := FArquivoSelecionado;
  end;
  UpdateClientControls;
end;

procedure TfrmTransfer.btnEnviarClick(Sender: TObject);
var
  LFileBytes, LEnvelope: TBytes;
  LStream: TFileStream;
  LNomeArquivo: string;
  LStatsAntes, LStatsDepois: TPipeClientStats;
  LBytesLogico, LBytesWire: UInt64;
begin
  if (FClient = nil) or (FArquivoSelecionado = '') then
    Exit;
  LNomeArquivo := ExtractFileName(FArquivoSelecionado);

  LStream := TFileStream.Create(FArquivoSelecionado, fmOpenRead or fmShareDenyWrite);
  try
    LFileBytes := nil;
    SetLength(LFileBytes, LStream.Size);
    if LStream.Size > 0 then
      LStream.ReadBuffer(LFileBytes[0], LStream.Size);
  finally
    LStream.Free;
  end;
  LEnvelope := EncodeFileEnvelope(LNomeArquivo, LFileBytes);

  // Delta antes/depois em vez de ler Stats uma vez so': robusto mesmo se o
  // usuario ja tiver enviado outro arquivo nesta mesma sessao (Stats e'
  // cumulativo da sessao, nao por mensagem).
  LStatsAntes := FClient.Stats;
  Screen.Cursor := crHourglass;
  try
    try
      FClient.SendBytes(LEnvelope);
    except
      on E: EPipeError do
      begin
        Log('falha ao enviar "' + LNomeArquivo + '": ' + E.Message);
        Exit;
      end;
    end;
  finally
    Screen.Cursor := crDefault;
  end;
  LStatsDepois := FClient.Stats;

  LBytesLogico := LStatsDepois.BytesSent - LStatsAntes.BytesSent;
  LBytesWire := LStatsDepois.BytesSentWire - LStatsAntes.BytesSentWire;
  Log(Format(
    'enviado "%s" (%d bytes de arquivo): %d bytes logicos no frame, %d no fio (economia: %s)',
    [LNomeArquivo, Length(LFileBytes), LBytesLogico, LBytesWire,
     PercentSaved(LBytesLogico, LBytesWire)]));
end;

{ --- comum --- }

procedure TfrmTransfer.AnyError(Sender: TObject; AConnId: TPipeConnectionId;
  const AError: string);
begin
  Log('erro: ' + AError);
end;

procedure TfrmTransfer.btnDesligarClick(Sender: TObject);
begin
  FreeAndNil(FClient); // Disconnect sincrono no destructor
  FreeAndNil(FServer); // Stop sincrono no destructor
  FArquivoSelecionado := '';
  edtArquivo.Text := '';
  lblStatus.Caption := 'parado';
  Log('desligado.');
  SetUiLigada(False);
end;

procedure TfrmTransfer.FormDestroy(Sender: TObject);
begin
  // Eventos pdmMainThread que ainda estiverem na fila viram no-op depois
  // daqui (objeto-guarda da lib) — fechar a janela no meio do trafego e' seguro.
  FreeAndNil(FClient);
  FreeAndNil(FServer);
end;

end.
