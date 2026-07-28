program ServicoLocal;

{ O servico de tras do sample GatewaySeguro: um TPipeServer em ptLocal que NAO
  SABE O QUE E' TLS — e nem precisa saber. E' o servico que quase toda casa tem:
  fala IPC local, nunca vai aprender TLS, e mesmo assim precisa ser exposto a
  rede com autenticacao. Quem resolve isso e' o GatewaySeguro, na frente dele.

  O servico e' bobo de proposito (eco com carimbo), mas faz uma coisa que
  importa: REGISTRA A IDENTIDADE DO CHAMADOR que o gateway informou no primeiro
  frame da conexao (IDENT|<commonName>, ver Gateway.Protocolo) e carimba cada
  resposta com ela. E' assim que a prova de identidade fica visivel do outro
  lado da rede.

  POR QUE ACREDITAR NO "IDENT|"? Porque ptLocal herda o controle de acesso do
  SISTEMA OPERACIONAL: so processos da propria maquina alcancam este pipe/socket,
  e na pratica o gateway e' a unica coisa que fala com ele. Se este servico
  estivesse em ptTcp ouvindo em 0.0.0.0, o esquema inteiro cairia — qualquer um
  na rede pularia o gateway e se declararia quem quisesse. A seguranca do
  desenho nao vem do gateway; vem do ALCANCE do transporte que esta aqui atras.

  Uso: ServicoLocal [nome-do-pipe]   (padrao pipes_faa_servico_local)
  Enter encerra.

  Compila nos dois mundos a partir do MESMO fonte:
    FPC (Windows): lazbuild ServicoLocal.lpi
    FPC (Linux):   fpc -MDelphi -Sh -Fu../../src -Fi../../src ServicoLocal.dpr
                   (este executavel nao usa TLS, entao nao precisa de
                   -dPIPES_OPENSSL; o gateway e o cliente remoto precisam)
    Delphi:        abrir ServicoLocal.dproj no IDE }

{$I pipes.inc}

{$IFNDEF FPC}
  {$APPTYPE CONSOLE}
{$ENDIF}

uses
  {$IFDEF FPC}
    {$IFDEF UNIX}
  cthreads, // threads reais no Unix: sem isso os eventos/condvars da lib falham em runtime
    {$ENDIF}
  {$ENDIF}
  SysUtils,
  Classes,
  SyncObjs,
  Generics.Collections,
  Pipes.Types,
  Pipes.Framing,
  Pipes.Base,
  Pipes.Server,
  Gateway.Protocolo in 'Gateway.Protocolo.pas';

type
  { Callbacks sao 'of object': o estado do sample vive nesta classe. }
  TServicoLocalApp = class
  private
    FServer: TPipeServer;
    FConsoleLock: TCriticalSection;
    // Quem esta do outro lado de cada conexao do gateway, segundo o IDENT|.
    FQuem: TDictionary<TPipeConnectionId, string>;
    FQuemLock: TCriticalSection;
    procedure Log(const AMsg: string);
    function IdentidadeDe(AConnId: TPipeConnectionId): string;
    procedure OnMsg(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure OnConn(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnDisc(Sender: TObject; AConnId: TPipeConnectionId);
    procedure OnErr(Sender: TObject; AConnId: TPipeConnectionId;
      const AError: string);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run(const APipeName: string);
  end;

constructor TServicoLocalApp.Create;
begin
  inherited Create;
  FConsoleLock := TCriticalSection.Create;
  FQuemLock := TCriticalSection.Create;
  FQuem := TDictionary<TPipeConnectionId, string>.Create;
end;

destructor TServicoLocalApp.Destroy;
begin
  FServer.Free; // Stop no destructor
  FQuem.Free;
  FQuemLock.Free;
  FConsoleLock.Free;
  inherited;
end;

procedure TServicoLocalApp.Log(const AMsg: string);
begin
  FConsoleLock.Enter;
  try
    Writeln(AMsg);
  finally
    FConsoleLock.Leave;
  end;
end;

function TServicoLocalApp.IdentidadeDe(AConnId: TPipeConnectionId): string;
var
  LNome: string;
begin
  // Conexao que nunca mandou IDENT|: alguem falando com este pipe direto, sem
  // passar pelo gateway. O servico responde, mas nao inventa um nome.
  Result := '(anonimo)';
  FQuemLock.Enter;
  try
    if FQuem.TryGetValue(AConnId, LNome) then
      Result := LNome;
  finally
    FQuemLock.Leave;
  end;
end;

procedure TServicoLocalApp.OnMsg(Sender: TObject; AConnId: TPipeConnectionId;
  const AData: TBytes);
var
  LCommonName, LTexto: string;
begin
  if GatewayEhIdent(AData, LCommonName) then
  begin
    FQuemLock.Enter;
    try
      FQuem.AddOrSetValue(AConnId, LCommonName);
    finally
      FQuemLock.Leave;
    end;
    Log(Format('[conn %d] o gateway diz que quem chama e "%s"',
      [AConnId, LCommonName]));
    Exit;
  end;

  LTexto := PipeUtf8Decode(AData);
  Log(Format('[conn %d] %s pediu: %s', [AConnId, IdentidadeDe(AConnId), LTexto]));
  try
    // O carimbo e' o ponto do sample: a resposta que chega la' na outra maquina
    // traz o nome que o CERTIFICADO do chamador provou no gateway.
    FServer.SendText(AConnId, Format('eco[%s @ %s]: %s',
      [IdentidadeDe(AConnId), FormatDateTime('hh:nn:ss', Now), LTexto]));
  except
    on E: EPipeError do
      Log(Format('[conn %d] resposta perdida (gateway caiu?): %s',
        [AConnId, E.Message]));
  end;
end;

procedure TServicoLocalApp.OnConn(Sender: TObject; AConnId: TPipeConnectionId);
begin
  // Aqui ainda NAO se sabe quem e': ptLocal nao tem identidade nenhuma. O nome
  // so' chega no IDENT|, que o gateway manda como primeiro frame da conexao.
  Log(Format('[conn %d] o gateway abriu uma conexao (%d no total)',
    [AConnId, FServer.ClientCount]));
end;

procedure TServicoLocalApp.OnDisc(Sender: TObject; AConnId: TPipeConnectionId);
begin
  Log(Format('[conn %d] %s saiu (%d no total)',
    [AConnId, IdentidadeDe(AConnId), FServer.ClientCount]));
  FQuemLock.Enter;
  try
    FQuem.Remove(AConnId);
  finally
    FQuemLock.Leave;
  end;
end;

procedure TServicoLocalApp.OnErr(Sender: TObject; AConnId: TPipeConnectionId;
  const AError: string);
begin
  Log(Format('[conn %d] erro: %s', [AConnId, AError]));
end;

procedure TServicoLocalApp.Run(const APipeName: string);
begin
  FServer := TPipeServer.Create(APipeName, ptLocal);
  // pdmSerialized porque a ORDEM importa nesta conexao: o IDENT| precisa ser
  // processado antes das mensagens que vem atras dele. Em pdmPool nao ha ordem
  // garantida nem entre duas mensagens da MESMA conexao — cada uma vira um work
  // item independente no pool global —, e o primeiro pedido poderia ser
  // carimbado como "(anonimo)".
  FServer.DispatchMode := pdmSerialized;
  FServer.OnMessage := OnMsg;
  FServer.OnClientConnected := OnConn;
  FServer.OnClientDisconnected := OnDisc;
  FServer.OnError := OnErr;
  FServer.Listen; // nao-blocante

  Log(Format('servico local escutando em "%s" (ptLocal, sem TLS) - Enter encerra',
    [APipeName]));
  Log('rode o GatewaySeguro noutro terminal para expor este servico a rede.');
  Readln;
  FServer.Stop; // sincrono: join de tudo, drena callbacks em voo
  Log('encerrado.');
end;

var
  App: TServicoLocalApp;
  PipeName: string;
begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  if ParamCount >= 1 then
    PipeName := ParamStr(1)
  else
    PipeName := 'pipes_faa_servico_local';
  App := TServicoLocalApp.Create;
  try
    App.Run(PipeName);
  finally
    App.Free;
  end;
end.
