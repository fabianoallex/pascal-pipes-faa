object frmTransfer: TfrmTransfer
  Left = 200
  Top = 120
  Caption = 'Transferencia de Arquivos (pascal-pipes-faa)'
  ClientHeight = 450
  ClientWidth = 560
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poScreenCenter
  OnDestroy = FormDestroy
  TextHeight = 15
  object lblPipe: TLabel
    Left = 8
    Top = 12
    Width = 26
    Height = 15
    Caption = 'Pipe:'
  end
  object lblStatus: TLabel
    Left = 300
    Top = 42
    Width = 36
    Height = 15
    Caption = 'parado'
  end
  object edtPipeName: TEdit
    Left = 44
    Top = 8
    Width = 136
    Height = 23
    TabOrder = 0
    Text = 'pipes_faa_arquivos'
  end
  object btnServidor: TButton
    Left = 188
    Top = 7
    Width = 100
    Height = 25
    Caption = 'Ser servidor'
    TabOrder = 1
    OnClick = btnServidorClick
  end
  object btnCliente: TButton
    Left = 296
    Top = 7
    Width = 100
    Height = 25
    Caption = 'Ser cliente'
    TabOrder = 2
    OnClick = btnClienteClick
  end
  object btnDesligar: TButton
    Left = 404
    Top = 7
    Width = 100
    Height = 25
    Caption = 'Desligar'
    Enabled = False
    TabOrder = 3
    OnClick = btnDesligarClick
  end
  object chkComprimir: TCheckBox
    Left = 8
    Top = 40
    Width = 280
    Height = 17
    Caption = 'Comprimir envio (CompressionMinSize)'
    TabOrder = 4
  end
  object edtArquivo: TEdit
    Left = 8
    Top = 68
    Width = 428
    Height = 23
    ReadOnly = True
    TabOrder = 5
  end
  object btnEscolherArquivo: TButton
    Left = 444
    Top = 66
    Width = 108
    Height = 25
    Caption = 'Selecionar...'
    Enabled = False
    TabOrder = 6
    OnClick = btnEscolherArquivoClick
  end
  object btnEnviar: TButton
    Left = 8
    Top = 98
    Width = 140
    Height = 25
    Caption = 'Enviar arquivo'
    Enabled = False
    TabOrder = 7
    OnClick = btnEnviarClick
  end
  object memoLog: TMemo
    Left = 8
    Top = 132
    Width = 544
    Height = 310
    Anchors = [akLeft, akTop, akRight, akBottom]
    ReadOnly = True
    ScrollBars = ssVertical
    TabOrder = 8
  end
  object OpenDialog1: TOpenDialog
    Filter = 'Todos os arquivos (*.*)|*.*'
    Left = 500
    Top = 8
  end
end
