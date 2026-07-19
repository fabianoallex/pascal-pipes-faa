object frmChatSeguro: TfrmChatSeguro
  Left = 200
  Top = 120
  Caption = 'Chat seguro (ptTls + mTLS) - pascal-pipes-faa'
  ClientHeight = 460
  ClientWidth = 700
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poScreenCenter
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  TextHeight = 15
  object lblEndereco: TLabel
    Left = 8
    Top = 12
    Width = 55
    Height = 15
    Caption = 'Endereco:'
  end
  object lblIdentidade: TLabel
    Left = 232
    Top = 12
    Width = 60
    Height = 15
    Caption = 'Identidade:'
  end
  object lblStatus: TLabel
    Left = 8
    Top = 44
    Width = 36
    Height = 15
    Caption = 'parado'
  end
  object lblSala: TLabel
    Left = 496
    Top = 76
    Width = 60
    Height = 15
    Anchors = [akTop, akRight]
    Caption = 'Na sala (0):'
  end
  object edtEndereco: TEdit
    Left = 70
    Top = 8
    Width = 152
    Height = 23
    TabOrder = 0
    Text = '127.0.0.1:5000'
  end
  object cbxIdentidade: TComboBox
    Left = 298
    Top = 8
    Width = 130
    Height = 23
    ItemIndex = 0
    TabOrder = 1
    Text = 'cli'
    Items.Strings = (
      'cli'
      'rogue'
      'selfsigned')
  end
  object btnHub: TButton
    Left = 440
    Top = 8
    Width = 76
    Height = 25
    Caption = 'Subir hub'
    TabOrder = 2
    OnClick = btnHubClick
  end
  object btnEntrar: TButton
    Left = 522
    Top = 8
    Width = 76
    Height = 25
    Caption = 'Entrar'
    TabOrder = 3
    OnClick = btnEntrarClick
  end
  object btnDesligar: TButton
    Left = 604
    Top = 8
    Width = 80
    Height = 25
    Caption = 'Desligar'
    Enabled = False
    TabOrder = 4
    OnClick = btnDesligarClick
  end
  object memoLog: TMemo
    Left = 8
    Top = 76
    Width = 480
    Height = 300
    Anchors = [akLeft, akTop, akRight, akBottom]
    ReadOnly = True
    ScrollBars = ssVertical
    TabOrder = 5
  end
  object lstSala: TListBox
    Left = 496
    Top = 96
    Width = 188
    Height = 280
    Anchors = [akTop, akRight, akBottom]
    ItemHeight = 15
    TabOrder = 6
  end
  object edtMensagem: TEdit
    Left = 8
    Top = 388
    Width = 592
    Height = 23
    Anchors = [akLeft, akRight, akBottom]
    TabOrder = 7
  end
  object btnEnviar: TButton
    Left = 608
    Top = 386
    Width = 76
    Height = 27
    Anchors = [akRight, akBottom]
    Caption = 'Enviar'
    Default = True
    TabOrder = 8
    OnClick = btnEnviarClick
  end
end
