program GatewaySeguro;

{ Gateway ptTls -> ptLocal: autentica o cliente remoto por mTLS e repassa o
  trafego, opaco, a um servico local que nao sabe o que e' TLS.

    [ClienteRemoto] --ptTls + mTLS--> [GatewaySeguro] --ptLocal--> [ServicoLocal]
       outra maquina                  autentica, repassa           nao sabe o que
                                                                   e' TLS

  E' o unico sample em que TPipeServer e TPipeClient estao VIVOS AO MESMO TEMPO
  no mesmo processo, e com transportes diferentes em cada ponta. Os outros
  samples provam que o alcance e' uma property; este prova que os alcances se
  COMPOEM.

  O racional inteiro — de onde vem a seguranca do desenho, as invariantes de
  lock, por que nenhum Free acontece dentro de callback e o que ficou fora
  desta versao — esta no cabecalho de Gateway.Nucleo.pas. Este arquivo e' so' a
  casca de console: sobe o gateway, imprime o painel e espera comandos.

  Credenciais: PKI de TESTE versionada em tests/pki (ver o LEIA-ME de la — NAO
  tem valor de seguranca, nunca reaproveitar fora da suite/deste sample).

  Uso: GatewaySeguro [endereco-tls] [pipe-local] [max-remotos]
       (padroes: 0.0.0.0:5000, pipes_faa_servico_local, 8)
  Comandos no console: list | sair

  Compila nos dois mundos a partir do MESMO fonte:
    FPC (Windows): lazbuild GatewaySeguro.lpi
    FPC (Linux):   fpc -MDelphi -Sh -Fu../../src -Fi../../src -dPIPES_OPENSSL \
                     GatewaySeguro.dpr
                   (SChannel nao existe fora do Windows; -dPIPES_OPENSSL e'
                   obrigatorio para ligar o backend TLS no Linux)
    Delphi:        abrir GatewaySeguro.dproj no IDE }

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
  Pipes.Types,
  Pipes.Framing,
  Pipes.Base,
  Pipes.Server,
  Pipes.Client,
  Gateway.Protocolo in 'Gateway.Protocolo.pas',
  Gateway.Nucleo in 'Gateway.Nucleo.pas';

// Procura 'tests/pki' subindo a partir de ADir. '' se nao achar. Mesma logica
// de tests/Integration/Pipes.TlsTests.pas: o executavel pode acabar em pastas
// diferentes (raiz do sample ou Win64/Debug, no build Delphi).
function ProcuraPkiAcimaDe(const ADir: string): string;
var
  LDir: string;
  I: Integer;
begin
  Result := '';
  LDir := IncludeTrailingPathDelimiter(ADir);
  for I := 0 to 6 do
  begin
    if FileExists(LDir + 'tests' + PathDelim + 'pki' + PathDelim +
         'ca_cert.pem') then
      Exit(LDir + 'tests' + PathDelim + 'pki' + PathDelim);
    LDir := LDir + '..' + PathDelim;
  end;
end;

function PkiDir: string;
begin
  Result := ProcuraPkiAcimaDe(ExtractFilePath(ParamStr(0)));
  if Result = '' then
    Result := ProcuraPkiAcimaDe(GetCurrentDir);
end;

type
  TGatewayApp = class
  private
    FGateway: TGatewaySeguro;
    FConsoleLock: TCriticalSection;
    procedure Log(Sender: TObject; const AMsg: string);
    procedure Escreve(const AMsg: string);
    procedure MostraPainel;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run(const AEnderecoTls, AEnderecoLocal: string;
      AMaxRemotos: Integer);
  end;

constructor TGatewayApp.Create;
begin
  inherited Create;
  FConsoleLock := TCriticalSection.Create;
end;

destructor TGatewayApp.Destroy;
begin
  FGateway.Free; // Parar no destructor
  FConsoleLock.Free;
  inherited;
end;

procedure TGatewayApp.Escreve(const AMsg: string);
begin
  // O log vem de varias threads (pool do servidor TLS, pool dos clientes
  // locais, ceifador): sem o lock as linhas se entrelacam.
  FConsoleLock.Enter;
  try
    Writeln(AMsg);
  finally
    FConsoleLock.Leave;
  end;
end;

procedure TGatewayApp.Log(Sender: TObject; const AMsg: string);
begin
  Escreve(AMsg);
end;

{ "2m14s" a partir de um instante de inicio. }
function Decorrido(ADesde: TDateTime): string;
var
  LSegundos: Int64;
begin
  LSegundos := Round((Now - ADesde) * 24 * 60 * 60);
  if LSegundos < 0 then
    LSegundos := 0;
  if LSegundos < 60 then
    Result := Format('%ds', [LSegundos])
  else
    Result := Format('%dm%.2ds', [LSegundos div 60, LSegundos mod 60]);
end;

procedure TGatewayApp.MostraPainel;
var
  LPainel: TGatewayPainel;
  I: Integer;
begin
  LPainel := FGateway.Painel;
  if Length(LPainel) = 0 then
    Escreve('  (nenhuma conexao remota)')
  else
    for I := 0 to High(LPainel) do
      Escreve(Format('  [remota %d] %-16s ->  local #%-3d (%s, %d msgs)',
        [LPainel[I].ConnRemota, LPainel[I].Identidade, LPainel[I].LocalSeq,
         Decorrido(LPainel[I].Desde), LPainel[I].Mensagens]));
end;

procedure TGatewayApp.Run(const AEnderecoTls, AEnderecoLocal: string;
  AMaxRemotos: Integer);
var
  LPki, LComando: string;
begin
  LPki := PkiDir;
  if LPki = '' then
    raise Exception.Create('tests/pki nao encontrada a partir de ' +
      ParamStr(0) + ' - este sample usa a PKI de teste versionada no repositorio');

  FGateway := TGatewaySeguro.Create(AEnderecoTls, AEnderecoLocal, AMaxRemotos);
  FGateway.OnLog := Log;
  FGateway.Iniciar(LPki);

  Escreve(Format('gateway no ar: %s (ptTls + mTLS)  ->  "%s" (ptLocal)',
    [AEnderecoTls, AEnderecoLocal]));
  Escreve(Format('max %d conexoes remotas (cada uma abre UMA conexao local)',
    [AMaxRemotos]));
  // Vazio ate o primeiro handshake — o Listen e' nao-blocante e nao negocia
  // nada sozinho; o nucleo loga de novo quando o primeiro cliente autentica.
  Escreve('backend TLS: ' + PipeTlsBackendInfo);
  Escreve('comandos: list | sair');
  repeat
    Readln(LComando);
    LComando := Trim(LComando);
    if SameText(LComando, 'list') then
      MostraPainel
    else if (LComando <> '') and not SameText(LComando, 'sair') then
      Escreve('comandos: list | sair');
  until SameText(LComando, 'sair');

  FGateway.Parar; // sincrono
  Escreve('encerrado.');
end;

var
  App: TGatewayApp;
  EnderecoTls, EnderecoLocal: string;
  MaxRemotos: Integer;
begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  if ParamCount >= 1 then
    EnderecoTls := ParamStr(1)
  else
    EnderecoTls := '0.0.0.0:5000';
  if ParamCount >= 2 then
    EnderecoLocal := ParamStr(2)
  else
    EnderecoLocal := 'pipes_faa_servico_local';
  MaxRemotos := 8;
  if ParamCount >= 3 then
    MaxRemotos := StrToIntDef(ParamStr(3), 8);
  App := TGatewayApp.Create;
  try
    App.Run(EnderecoTls, EnderecoLocal, MaxRemotos);
  finally
    App.Free;
  end;
end.
