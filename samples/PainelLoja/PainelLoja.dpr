program PainelLoja;

{ Pub/sub por topicos: uma retaguarda, N caixas e um painel de supervisao, todos
  no MESMO executavel, escolhidos pelo primeiro parametro.

  O cenario e' o do PDV de loja: cada caixa publica o proprio status, o painel
  quer ver o de todos sem saber quantos existem, e a retaguarda publica a versao
  da tabela de precos — que um caixa recem-ligado precisa conhecer sem ter de
  pedir. E' esse ultimo detalhe que o retain resolve.

  O que este sample mostra e os outros nao:

  1. ENDERECAMENTO POR ASSUNTO, e nao por conexao. Ninguem chama SendBytes com
     ConnId nenhum: a retaguarda publica em 'loja.tabela.versao' e quem assinou
     recebe. Adicionar um caixa nao muda uma linha de codigo da retaguarda.

  2. CURINGAS fazendo trabalho de verdade: o caixa assina o proprio
     'caixa.<n>.comando' (so' o que e' dele), e o painel assina 'caixa.#' (tudo
     de todos, inclusive de caixas que ainda nao existem).

  3. RELAY DESLIGADO, que e' o padrao, e por que isso e' bom: a publicacao de um
     caixa NAO chega automaticamente aos outros. Ela chega a retaguarda em
     OnPublish, que confere se o topico esta no lugar certo e so' entao
     republica — com retain, para que o painel que abrir depois veja o ultimo
     status de cada caixa em vez de uma tela vazia. Ligar RelayClientPublish
     seria uma linha, e deixaria qualquer caixa publicar em qualquer topico.

  4. O QUE O RETAIN NAO E': ele nao guarda historico, guarda o ULTIMO valor de
     cada topico. Feche e reabra o painel: ele reconstroi o estado atual, nao a
     conversa. Mensagem que precisa sobreviver ao processo pede fila (e outra
     biblioteca).

  5. Publicar sem estar conectado LEVANTA (diferente de assinar): o caixa em
     reconexao registra a falha e segue, e a lib reenvia as ASSINATURAS dele
     sozinha quando a sessao volta — sem nada no OnConnected.

  Uso (uma janela para cada, na ordem que quiser):
    PainelLoja retaguarda [endereco]
    PainelLoja caixa 3    [endereco]
    PainelLoja painel     [endereco]
  Endereco padrao: 'pipes_faa_painel' (ptLocal). Para duas maquinas, passe
  'host:porta' nos tres e troque o Transport (uma linha em CriarServidor/
  CriarCliente).

  Compila nos dois mundos a partir do MESMO fonte:
    FPC:    lazbuild PainelLoja.lpi
    Delphi: abrir PainelLoja.dproj no IDE }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ELSE}
  {$APPTYPE CONSOLE}
{$ENDIF}

uses
  {$IFDEF FPC}
    {$IFDEF UNIX}
  cthreads, // threads reais no Unix: sem isso os eventos/condvars da lib falham
    {$ENDIF}
  {$ENDIF}
  SysUtils,
  Classes,
  SyncObjs,
  Pipes.Types,
  Pipes.Framing,
  Pipes.Topics,
  Pipes.Server,
  Pipes.Client;

const
  ENDERECO_PADRAO = 'pipes_faa_painel';
  // Topico da versao da tabela de precos. Publicado com retain: quem conectar
  // depois recebe o valor corrente na hora em que assinar.
  TOPICO_TABELA = 'loja.tabela.versao';
  // Filtro que a retaguarda considera legitimo para um caixa publicar.
  FILTRO_STATUS_CAIXA = 'caixa.*.status';

type
  TTickEvent = procedure(ATick: Integer) of object;

  { Relogio de fundo: chama FOnTick a cada intervalo ate ser parado. Espera num
    TEvent, e nao em Sleep, para que Parar() nao fique esperando o intervalo
    inteiro terminar. Callback 'of object' (a lib nao usa metodos anonimos). }
  TRelogio = class(TThread)
  private
    FIntervaloMs: Cardinal;
    FEvento: TEvent;
    FOnTick: TTickEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(AIntervaloMs: Cardinal; AOnTick: TTickEvent);
    destructor Destroy; override;
    procedure Parar;
  end;

  { Base dos tres papeis: so' o log serializado, que todos precisam porque os
    callbacks da lib rodam em threads do pool e WriteLn concorrente embaralha. }
  TPapel = class
  private
    FConsoleLock: TCriticalSection;
  protected
    procedure Log(const AMsg: string);
  public
    constructor Create;
    destructor Destroy; override;
  end;

  { --- retaguarda: o unico servidor --- }
  TRetaguarda = class(TPapel)
  private
    FServer: TPipeServer;
    FRelogio: TRelogio;
    FVersao: Integer;
    procedure OnPublicacaoDeCliente(Sender: TObject; AConnId: TPipeConnectionId;
      const ATopic: string; const AData: TBytes; ARetained: Boolean);
    procedure OnAssinou(Sender: TObject; AConnId: TPipeConnectionId;
      const AFilter: string);
    procedure OnCancelou(Sender: TObject; AConnId: TPipeConnectionId;
      const AFilter: string);
    procedure OnConectou(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnDesconectou(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnErro(Sender: TObject; AConnId: TPipeConnectionId;
      const AError: string);
    procedure PublicarTabela(ATick: Integer);
  public
    procedure Run(const AEndereco: string);
  end;

  { --- caixa: cliente que publica status e obedece comandos --- }
  TCaixa = class(TPapel)
  private
    FClient: TPipeClient;
    FRelogio: TRelogio;
    FNumero: string;
    procedure OnTopico(Sender: TObject; AConnId: TPipeConnectionId;
      const ATopic: string; const AData: TBytes; ARetained: Boolean);
    procedure OnConectou(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnDesconectou(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnErro(Sender: TObject; AConnId: TPipeConnectionId;
      const AError: string);
    procedure PublicarStatus(ATick: Integer);
  public
    procedure Run(const ANumero, AEndereco: string);
  end;

  { --- painel: cliente que so' observa --- }
  TPainel = class(TPapel)
  private
    FClient: TPipeClient;
    procedure OnTopico(Sender: TObject; AConnId: TPipeConnectionId;
      const ATopic: string; const AData: TBytes; ARetained: Boolean);
    procedure OnConectou(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnDesconectou(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnErro(Sender: TObject; AConnId: TPipeConnectionId;
      const AError: string);
  public
    procedure Run(const AEndereco: string);
  end;

{ TRelogio }

constructor TRelogio.Create(AIntervaloMs: Cardinal; AOnTick: TTickEvent);
begin
  FIntervaloMs := AIntervaloMs;
  FOnTick := AOnTick;
  FEvento := TEvent.Create(nil, True, False, ''); // manual-reset
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TRelogio.Destroy;
begin
  FEvento.Free;
  inherited;
end;

procedure TRelogio.Parar;
begin
  Terminate;
  FEvento.SetEvent; // acorda a espera em curso
end;

procedure TRelogio.Execute;
var
  LTick: Integer;
begin
  LTick := 0;
  while not Terminated do
  begin
    FEvento.WaitFor(FIntervaloMs);
    if Terminated then
      Break;
    Inc(LTick);
    try
      FOnTick(LTick);
    except
      on E: Exception do
        ; // um tick que falha nao derruba o relogio (quem loga e' o callback)
    end;
  end;
end;

{ TPapel }

constructor TPapel.Create;
begin
  inherited Create;
  FConsoleLock := TCriticalSection.Create;
end;

destructor TPapel.Destroy;
begin
  FConsoleLock.Free;
  inherited;
end;

procedure TPapel.Log(const AMsg: string);
begin
  FConsoleLock.Enter;
  try
    Writeln(FormatDateTime('hh:nn:ss', Now), '  ', AMsg);
  finally
    FConsoleLock.Leave;
  end;
end;

{ TRetaguarda }

procedure TRetaguarda.OnPublicacaoDeCliente(Sender: TObject;
  AConnId: TPipeConnectionId; const ATopic: string; const AData: TBytes;
  ARetained: Boolean);
begin
  // RelayClientPublish esta DESLIGADO (padrao), entao nada saiu daqui para os
  // outros clientes ainda: a decisao e' desta funcao.
  //
  // A regra e' de topico, nao de identidade — 'caixa.9.status' passaria mesmo
  // vindo do caixa 3. Num sistema real com ptTls + mTLS, e' aqui que se compara
  // TryClientIdentity(AConnId).CommonName com o segmento do topico; sem
  // certificado nao ha o que comparar, e este sample nao finge que ha.
  if not PipeTopicMatches(FILTRO_STATUS_CAIXA, ATopic) then
  begin
    Log(Format('[conn %d] RECUSADO publicar em "%s" (esperado %s)',
      [AConnId, ATopic, FILTRO_STATUS_CAIXA]));
    Exit; // caso queira ser severo: FServer.DisconnectClient(AConnId);
  end;
  Log(Format('[conn %d] %s = %s (retransmitindo)',
    [AConnId, ATopic, PipeUtf8Decode(AData)]));
  // Retain: o painel que abrir depois recebe o ultimo status de cada caixa em
  // vez de ficar em branco esperando o proximo tick.
  FServer.Publish(ATopic, AData, True);
end;

procedure TRetaguarda.OnAssinou(Sender: TObject; AConnId: TPipeConnectionId;
  const AFilter: string);
begin
  // Notificacao: a assinatura JA esta valendo (e os valores retidos que casam
  // com ela ja foram enviados). Para negar, seria DisconnectClient aqui.
  Log(Format('[conn %d] assinou "%s"', [AConnId, AFilter]));
end;

procedure TRetaguarda.OnCancelou(Sender: TObject; AConnId: TPipeConnectionId;
  const AFilter: string);
begin
  Log(Format('[conn %d] cancelou "%s"', [AConnId, AFilter]));
end;

procedure TRetaguarda.OnConectou(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log(Format('[conn %d] conectou (%d cliente(s))',
    [AConnId, FServer.ClientCount]));
end;

procedure TRetaguarda.OnDesconectou(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  // As assinaturas desta conexao morreram com ela: nao ha nada a limpar aqui.
  Log(Format('[conn %d] desconectou (%d cliente(s))',
    [AConnId, FServer.ClientCount]));
end;

procedure TRetaguarda.OnErro(Sender: TObject; AConnId: TPipeConnectionId;
  const AError: string);
begin
  Log(Format('[conn %d] erro: %s', [AConnId, AError]));
end;

procedure TRetaguarda.PublicarTabela(ATick: Integer);
begin
  Inc(FVersao);
  // Publicar sem assinante nenhum nao e' erro e nao enfileira nada — mas com
  // retain o valor fica guardado, e e' isso que faz o caixa que ligar amanha
  // saber a versao de hoje.
  FServer.PublishText(TOPICO_TABELA, 'v' + IntToStr(FVersao), True);
  Log(Format('publicou %s = v%d (%d assinante(s))',
    [TOPICO_TABELA, FVersao, FServer.SubscriberCount(TOPICO_TABELA)]));
end;

procedure TRetaguarda.Run(const AEndereco: string);
begin
  FServer := TPipeServer.Create(AEndereco);
  // FServer.Transport := ptTcp; // duas maquinas: Address = 'host:porta'
  FServer.OnPublish := OnPublicacaoDeCliente;
  FServer.OnSubscribe := OnAssinou;
  FServer.OnUnsubscribe := OnCancelou;
  FServer.OnClientConnected := OnConectou;
  FServer.OnClientDisconnected := OnDesconectou;
  FServer.OnError := OnErro;
  // Deixado explicito por ser a decisao central deste sample (o valor e' o
  // padrao): cliente NAO retransmite para cliente sem a retaguarda mandar.
  FServer.RelayClientPublish := False;
  try
    FServer.Listen;
    Log('retaguarda escutando em "' + AEndereco + '" - Enter encerra');
    PublicarTabela(0); // primeira versao ja fica retida
    FRelogio := TRelogio.Create(15000, PublicarTabela);
    try
      Readln;
      FRelogio.Parar;
      FRelogio.WaitFor;
    finally
      FRelogio.Free;
    end;
    FServer.Stop;
    Log('encerrada.');
  finally
    FServer.Free;
  end;
end;

{ TCaixa }

procedure TCaixa.OnTopico(Sender: TObject; AConnId: TPipeConnectionId;
  const ATopic: string; const AData: TBytes; ARetained: Boolean);
var
  LOrigem: string;
begin
  // Chega aqui SO' o que casa com algum filtro assinado. O caixa nao filtra
  // nada por conta: quem roteia e' o servidor.
  //
  // ARetained separa "a tabela mudou agora" de "esta e a versao que vigorava
  // quando eu liguei". O primeiro caso mereceria reimprimir etiqueta; o
  // segundo, so' saber. Confundir os dois e' o bug classico de quem recebe
  // catch-up e trata como evento.
  if ARetained then
    LOrigem := ' (retido: valor que ja vigorava)'
  else
    LOrigem := '';
  Log(Format('recebeu [%s] %s%s', [ATopic, PipeUtf8Decode(AData), LOrigem]));
end;

procedure TCaixa.OnConectou(Sender: TObject; AConnId: TPipeConnectionId);
begin
  // Nenhum Subscribe aqui de proposito: as assinaturas feitas em Run valem
  // para esta e para toda sessao futura — a lib as reenvia em cada reconexao,
  // ANTES deste evento. Reassinar aqui seria inofensivo, mas desnecessario.
  Log('conectado (assinaturas ja restauradas pela lib)');
end;

procedure TCaixa.OnDesconectou(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log('desconectado (AutoReconnect vai tentar de novo)');
end;

procedure TCaixa.OnErro(Sender: TObject; AConnId: TPipeConnectionId;
  const AError: string);
begin
  // Aqui aparece tambem a recusa de uma assinatura pelo servidor (filtro
  // invalido ou teto por cliente): Subscribe nao levanta por isso, porque a
  // resposta vem depois, do outro lado.
  Log('erro: ' + AError);
end;

procedure TCaixa.PublicarStatus(ATick: Integer);
var
  LStatus: string;
begin
  if (ATick mod 3) = 0 then
    LStatus := 'livre'
  else
    LStatus := 'ocupado (' + IntToStr(ATick) + ' venda(s))';
  try
    FClient.PublishText('caixa.' + FNumero + '.status', LStatus);
  except
    // Publicar exige sessao: numa janela de reconexao isto levanta, e o certo
    // e' registrar e seguir — o proximo tick tenta de novo. (As ASSINATURAS,
    // ao contrario, sobrevivem sozinhas.)
    on E: EPipeError do
      Log('nao consegui publicar agora: ' + E.Message);
  end;
end;

procedure TCaixa.Run(const ANumero, AEndereco: string);
begin
  FNumero := ANumero;
  FClient := TPipeClient.Create(AEndereco);
  // FClient.Transport := ptTcp; // duas maquinas: Address = 'host:porta'
  FClient.OnTopicMessage := OnTopico;
  FClient.OnConnected := OnConectou;
  FClient.OnDisconnected := OnDesconectou;
  FClient.OnError := OnErro;
  FClient.AutoReconnect := True;
  try
    // Assinar ANTES de conectar e' permitido e e' o melhor jeito: o filtro e'
    // estado desejado do cliente, e a lib o aplica assim que houver sessao.
    FClient.Subscribe('loja.#');                       // tudo da retaguarda
    FClient.Subscribe('caixa.' + ANumero + '.comando'); // so' os meus comandos
    FClient.Connect(5000);
    Log(Format('caixa %s conectado a "%s" - Enter encerra', [ANumero, AEndereco]));
    FRelogio := TRelogio.Create(3000, PublicarStatus);
    try
      Readln;
      FRelogio.Parar;
      FRelogio.WaitFor;
    finally
      FRelogio.Free;
    end;
    FClient.Disconnect;
    Log('encerrado.');
  finally
    FClient.Free;
  end;
end;

{ TPainel }

procedure TPainel.OnTopico(Sender: TObject; AConnId: TPipeConnectionId;
  const ATopic: string; const AData: TBytes; ARetained: Boolean);
var
  LMarca: string;
begin
  // A marca de retido e' o que torna visivel a diferenca entre o painel
  // desenhando o estado que JA existia e o painel acompanhando o que acontece.
  if ARetained then
    LMarca := 'ret '
  else
    LMarca := '    ';
  Log(Format('%s%-24s %s', [LMarca, ATopic, PipeUtf8Decode(AData)]));
end;

procedure TPainel.OnConectou(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log('conectado - o que chegar agora, sem esperar tick, e valor RETIDO');
end;

procedure TPainel.OnDesconectou(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log('desconectado');
end;

procedure TPainel.OnErro(Sender: TObject; AConnId: TPipeConnectionId;
  const AError: string);
begin
  Log('erro: ' + AError);
end;

procedure TPainel.Run(const AEndereco: string);
begin
  FClient := TPipeClient.Create(AEndereco);
  // FClient.Transport := ptTcp; // duas maquinas: Address = 'host:porta'
  FClient.OnTopicMessage := OnTopico;
  FClient.OnConnected := OnConectou;
  FClient.OnDisconnected := OnDesconectou;
  FClient.OnError := OnErro;
  FClient.AutoReconnect := True;
  try
    // Dois curingas: 'caixa.#' alcanca caixas que ainda nao existem, e a lista
    // de assinantes do servidor nao precisa saber quantos serao.
    FClient.Subscribe('caixa.#');
    FClient.Subscribe('loja.#');
    FClient.Connect(5000);
    Log('painel ligado a "' + AEndereco + '" - Enter encerra');
    Readln;
    FClient.Disconnect;
    Log('encerrado.');
  finally
    FClient.Free;
  end;
end;

procedure Ajuda;
begin
  Writeln('uso: PainelLoja retaguarda [endereco]');
  Writeln('     PainelLoja caixa <numero> [endereco]');
  Writeln('     PainelLoja painel [endereco]');
  Writeln('endereco padrao: ', ENDERECO_PADRAO);
end;

var
  Papel, Numero, Endereco: string;
  Retaguarda: TRetaguarda;
  Caixa: TCaixa;
  Painel: TPainel;
begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  Papel := LowerCase(ParamStr(1));
  if Papel = 'caixa' then
  begin
    Numero := ParamStr(2);
    if ParamCount >= 3 then Endereco := ParamStr(3) else Endereco := ENDERECO_PADRAO;
  end
  else
    if ParamCount >= 2 then Endereco := ParamStr(2) else Endereco := ENDERECO_PADRAO;

  if Papel = 'retaguarda' then
  begin
    Retaguarda := TRetaguarda.Create;
    try
      Retaguarda.Run(Endereco);
    finally
      Retaguarda.Free;
    end;
  end
  else if (Papel = 'caixa') and (Numero <> '') then
  begin
    Caixa := TCaixa.Create;
    try
      Caixa.Run(Numero, Endereco);
    finally
      Caixa.Free;
    end;
  end
  else if Papel = 'painel' then
  begin
    Painel := TPainel.Create;
    try
      Painel.Run(Endereco);
    finally
      Painel.Free;
    end;
  end
  else
    Ajuda;
end.
