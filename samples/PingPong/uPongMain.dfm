object frmPong: TfrmPong
  Left = 160
  Top = 90
  Caption = 'Ping Pong em rede (pascal-pipes-faa)'
  ClientHeight = 700
  ClientWidth = 900
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  KeyPreview = True
  Position = poScreenCenter
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  OnKeyDown = FormKeyDown
  OnKeyUp = FormKeyUp
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
  object lblDificuldade: TLabel
    Left = 564
    Top = 14
    Width = 74
    Height = 15
    Caption = 'Nivel do bot:'
  end
  object lblStatus: TLabel
    Left = 446
    Top = 46
    Width = 440
    Height = 15
    Anchors = [akTop, akLeft, akRight]
    AutoSize = False
    Caption = 'parado'
  end
  object lblAjuda: TLabel
    Left = 8
    Top = 100
    Width = 600
    Height = 15
    AutoSize = False
    Caption =
      'Setas cima/baixo (ou W/S) movem a sua raquete. Primeiro a fazer 7' +
      ' pontos vence.'
  end
  object pbCampo: TPaintBox
    Left = 8
    Top = 122
    Width = 884
    Height = 410
    Anchors = [akLeft, akTop, akRight, akBottom]
    OnPaint = pbCampoPaint
  end
  object edtEndereco: TEdit
    Left = 70
    Top = 10
    Width = 150
    Height = 23
    TabOrder = 0
    Text = 'pipes_faa_pong'
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
  object cbDificuldade: TComboBox
    Left = 648
    Top = 10
    Width = 120
    Height = 23
    Style = csDropDownList
    ItemIndex = 1
    TabOrder = 3
    Text = 'Medio'
    Items.Strings = (
      'Facil'
      'Medio'
      'Dificil')
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
    Left = 254
    Top = 74
    Width = 400
    Height = 19
    Caption = 'Computador ocupa a vaga do convidado (so hospedeiro)'
    TabOrder = 9
  end
  object memoLog: TMemo
    Left = 8
    Top = 542
    Width = 884
    Height = 148
    Anchors = [akLeft, akRight, akBottom]
    ReadOnly = True
    ScrollBars = ssVertical
    TabOrder = 10
    TabStop = False
  end
  object tmrJogo: TTimer
    Enabled = False
    Interval = 15
    OnTimer = tmrJogoTimer
    Left = 800
    Top = 130
  end
  object tmrDesligar: TTimer
    Enabled = False
    Interval = 50
    OnTimer = tmrDesligarTimer
    Left = 848
    Top = 130
  end
end
