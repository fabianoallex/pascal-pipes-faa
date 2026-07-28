object frmJogo: TfrmJogo
  Left = 180
  Top = 100
  Caption = 'Pontos e Caixas em rede (pascal-pipes-faa)'
  ClientHeight = 690
  ClientWidth = 820
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
    Top = 14
    Width = 58
    Height = 15
    Caption = 'Endereco:'
  end
  object lblApelido: TLabel
    Left = 386
    Top = 14
    Width = 46
    Height = 15
    Caption = 'Apelido:'
  end
  object lblTamanho: TLabel
    Left = 564
    Top = 14
    Width = 56
    Height = 15
    Caption = 'Tabuleiro:'
  end
  object lblStatus: TLabel
    Left = 446
    Top = 46
    Width = 366
    Height = 15
    Anchors = [akTop, akLeft, akRight]
    AutoSize = False
    Caption = 'parado'
  end
  object lblJogador0: TLabel
    Left = 8
    Top = 104
    Width = 260
    Height = 18
    AutoSize = False
    Caption = 'Hospedeiro: 0'
    ParentFont = False
  end
  object lblVez: TLabel
    Left = 280
    Top = 104
    Width = 260
    Height = 18
    Alignment = taCenter
    AutoSize = False
    Caption = 'Vez de: Hospedeiro'
    ParentFont = False
  end
  object lblJogador1: TLabel
    Left = 552
    Top = 104
    Width = 260
    Height = 18
    Alignment = taRightJustify
    Anchors = [akTop, akRight]
    AutoSize = False
    Caption = 'Convidado: 0'
    ParentFont = False
  end
  object pbTabuleiro: TPaintBox
    Left = 8
    Top = 128
    Width = 804
    Height = 400
    Anchors = [akTop, akLeft, akRight, akBottom]
    OnMouseDown = pbTabuleiroMouseDown
    OnMouseMove = pbTabuleiroMouseMove
    OnPaint = pbTabuleiroPaint
  end
  object edtEndereco: TEdit
    Left = 70
    Top = 10
    Width = 150
    Height = 23
    TabOrder = 0
    Text = 'pipes_faa_jogo'
  end
  object cbTransporte: TComboBox
    Left = 226
    Top = 10
    Width = 150
    Height = 23
    Style = csDropDownList
    ItemIndex = 0
    TabOrder = 1
    Text = 'Local (mesma maquina)'
    OnChange = cbTransporteChange
    Items.Strings = (
      'Local (mesma maquina)'
      'TCP (rede)')
  end
  object edtApelido: TEdit
    Left = 436
    Top = 10
    Width = 120
    Height = 23
    TabOrder = 2
  end
  object cbTamanho: TComboBox
    Left = 624
    Top = 10
    Width = 90
    Height = 23
    Style = csDropDownList
    ItemIndex = 1
    TabOrder = 3
    Text = '5 x 5'
    Items.Strings = (
      '3 x 3'
      '5 x 5'
      '7 x 7')
  end
  object btnHospedar: TButton
    Left = 8
    Top = 41
    Width = 100
    Height = 25
    Caption = 'Hospedar'
    TabOrder = 4
    OnClick = btnHospedarClick
  end
  object btnEntrar: TButton
    Left = 114
    Top = 41
    Width = 100
    Height = 25
    Caption = 'Entrar'
    TabOrder = 5
    OnClick = btnEntrarClick
  end
  object btnSair: TButton
    Left = 220
    Top = 41
    Width = 100
    Height = 25
    Caption = 'Sair'
    Enabled = False
    TabOrder = 6
    OnClick = btnSairClick
  end
  object btnNovaPartida: TButton
    Left = 326
    Top = 41
    Width = 110
    Height = 25
    Caption = 'Nova partida'
    Enabled = False
    TabOrder = 7
    OnClick = btnNovaPartidaClick
  end
  object chkBotPorMim: TCheckBox
    Left = 8
    Top = 74
    Width = 230
    Height = 19
    Caption = 'Computador joga por mim'
    TabOrder = 8
  end
  object chkBotConvidado: TCheckBox
    Left = 246
    Top = 74
    Width = 330
    Height = 19
    Caption = 'Computador ocupa a vaga do convidado (so hospedeiro)'
    TabOrder = 9
  end
  object memoLog: TMemo
    Left = 8
    Top = 540
    Width = 804
    Height = 142
    Anchors = [akLeft, akRight, akBottom]
    ReadOnly = True
    ScrollBars = ssVertical
    TabOrder = 10
  end
  object tmrDesligar: TTimer
    Enabled = False
    Interval = 50
    OnTimer = tmrDesligarTimer
    Left = 760
    Top = 108
  end
  object tmrAnimacao: TTimer
    Enabled = False
    Interval = 25
    OnTimer = tmrAnimacaoTimer
    Left = 712
    Top = 108
  end
  object tmrBot: TTimer
    Enabled = False
    Interval = 550
    OnTimer = tmrBotTimer
    Left = 664
    Top = 108
  end
end
