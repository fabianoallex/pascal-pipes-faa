unit Gateway.Protocolo;

{$I pipes.inc}

{ Protocolo MINIMO do gateway ptTls -> ptLocal.

  So existem DUAS mensagens aqui, e isso e' uma qualidade do desenho, nao uma
  limitacao: o gateway NAO entende o protocolo da aplicacao. Tudo o que nao for
  uma destas duas mensagens trafega opaco (TBytes repassado sem inspecao), o
  que permite por o gateway na frente de um servico qualquer sem ensinar nada
  a ele.

  - IDENT|<commonName>  gateway -> servico local. PRIMEIRA mensagem de cada
                        conexao local, antes de qualquer byte da aplicacao.
                        Diz ao servico quem e' o par remoto, porque ptLocal nao
                        tem TLS e portanto nao tem identidade nenhuma.
  - RECUSADO|<motivo>   gateway -> cliente remoto, quando a recusa e' de
                        APLICACAO (o handshake mTLS ja' passou). Carrega motivo
                        justamente porque um socket fechado calado nao
                        distingue "voce nao se autenticou" de "o servico de
                        tras esta fora do ar".

  Os testes de prefixo trabalham sobre os BYTES, nao sobre a string decodificada:
  o trafego da aplicacao e' opaco e pode ser binario qualquer, e decodificar
  como UTF-8 so' para comparar um prefixo estragaria payload valido. }

interface

uses
  SysUtils,
  Pipes.Types,
  Pipes.Framing;

const
  GW_PREFIXO_IDENT    = 'IDENT|';
  GW_PREFIXO_RECUSADO = 'RECUSADO|';

/// Frame de identidade, do gateway para o servico local.
function GatewayIdent(const ACommonName: string): TBytes;
/// Frame de recusa de aplicacao, do gateway para o cliente remoto.
function GatewayRecusado(const AMotivo: string): TBytes;
/// True se AData for um IDENT|; devolve o CommonName em ACommonName.
function GatewayEhIdent(const AData: TBytes; out ACommonName: string): Boolean;
/// True se AData for um RECUSADO|; devolve o motivo em AMotivo.
function GatewayEhRecusado(const AData: TBytes; out AMotivo: string): Boolean;

implementation

{ Compara o prefixo em BYTES e devolve o resto decodificado como UTF-8. }
function ComPrefixo(const AData: TBytes; const APrefixo: string;
  out AResto: string): Boolean;
var
  LPrefixo, LResto: TBytes;
  I: Integer;
begin
  AResto := '';
  SetLength(LResto, 0);
  LPrefixo := PipeUtf8Encode(APrefixo);
  if Length(AData) < Length(LPrefixo) then
    Exit(False);
  for I := 0 to High(LPrefixo) do
    if AData[I] <> LPrefixo[I] then
      Exit(False);
  SetLength(LResto, Length(AData) - Length(LPrefixo));
  if Length(LResto) > 0 then
    Move(AData[Length(LPrefixo)], LResto[0], Length(LResto));
  AResto := PipeUtf8Decode(LResto);
  Result := True;
end;

function GatewayIdent(const ACommonName: string): TBytes;
begin
  Result := PipeUtf8Encode(GW_PREFIXO_IDENT + ACommonName);
end;

function GatewayRecusado(const AMotivo: string): TBytes;
begin
  Result := PipeUtf8Encode(GW_PREFIXO_RECUSADO + AMotivo);
end;

function GatewayEhIdent(const AData: TBytes; out ACommonName: string): Boolean;
begin
  Result := ComPrefixo(AData, GW_PREFIXO_IDENT, ACommonName);
end;

function GatewayEhRecusado(const AData: TBytes; out AMotivo: string): Boolean;
begin
  Result := ComPrefixo(AData, GW_PREFIXO_RECUSADO, AMotivo);
end;

end.
