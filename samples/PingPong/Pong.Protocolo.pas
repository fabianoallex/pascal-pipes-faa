unit Pong.Protocolo;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

{ Contrato de mensagens do Ping Pong em rede. Unit pura: depende das regras
  (Pong.Partida) mas NAO da biblioteca de pipes — quem converte para TBytes e'
  o form, com SendText/BroadcastText.

  Formato de fio: uma linha de texto UTF-8 por mensagem, "KIND|campo|campo".

  Quem fala o que:

    CONVIDADO -> HOSPEDEIRO
      OI|token|apelido    identifica-se. Primeira coisa depois de cada Connect,
                          inclusive depois de reconexao automatica — e' o que
                          devolve a vaga ao mesmo jogador.
      ENTRADA|dir         "estou segurando cima (-1), nada (0) ou baixo (+1)".

    HOSPEDEIRO -> CONVIDADO
      ACEITO|indice       voce entrou, e e' o jogador <indice>.
      RECUSADO|motivo     voce nao entrou, e o motivo e' esse.
      AVISO|texto         recado avulso.
      ESTADO|...          a fotografia inteira do jogo. Ver abaixo.

  ENTRADA E' POR BORDA, NAO POR QUADRO. O convidado so' manda quando a direcao
  MUDA — soltar e apertar uma tecla, tipicamente algumas vezes por segundo, e
  nao 60. Isso so' e' seguro porque o transporte e' confiavel e ordenado: uma
  ENTRADA perdida nunca acontece. Em UDP a mesma decisao seria um bug (a
  raquete ficaria correndo para sempre se a mensagem de "parei" sumisse), e a
  solucao la' e' repetir o estado da tecla em todo pacote.

  O ESTADO vai no sentido contrario: e' NIVEL, mandado a cada
  PONG_TICKS_POR_SNAPSHOT passos independentemente de ter mudado algo. Cada um
  sobrescreve o anterior por completo, entao um atraso na rede se resolve
  sozinho quando a fila drena — o ultimo que chegou ja' e' a verdade atual.
  E' a mesma escolha do PontosECaixas (estado inteiro em vez de delta), aqui
  pela razao extra de que a bola nao tem "eventos" para mandar.

  NUMEROS DE PONTO FLUTUANTE VAO COMO INTEIRO EM CENTESIMOS, de proposito.
  FloatToStr/StrToFloat usam o separador decimal do LOCALE: um hospedeiro em
  pt-BR mandaria "412,75" e um convidado em en-US leria isso como erro de
  conversao (ou pior, como 412). Como o mundo tem 1000x600 unidades,
  centesimos sobram de precisao e o problema simplesmente deixa de existir. }

interface

uses
  SysUtils,
  Pong.Partida;

type
  TPongMsgKind = (
    pmkOi,        // convidado -> hospedeiro
    pmkEntrada,   // convidado -> hospedeiro
    pmkAceito,    // hospedeiro -> convidado
    pmkRecusado,  // hospedeiro -> convidado
    pmkAviso,     // hospedeiro -> convidado
    pmkEstado     // hospedeiro -> convidado
  );

  EPongProtocolo = class(Exception);

/// Le so' o KIND da linha. EPongProtocolo se a mensagem nao for reconhecida.
function PongMsgKindOf(const ALinha: string): TPongMsgKind;

function PongEncodeOi(const AToken, AApelido: string): string;
procedure PongDecodeOi(const ALinha: string; out AToken, AApelido: string);

function PongEncodeEntrada(ADirecao: Integer): string;
function PongDecodeEntrada(const ALinha: string): Integer;

function PongEncodeAceito(AIndice: Integer): string;
function PongDecodeAceito(const ALinha: string): Integer;

function PongEncodeRecusado(const AMotivo: string): string;
function PongEncodeAviso(const ATexto: string): string;
/// Texto de RECUSADO e AVISO (mesmo formato: um campo so').
function PongDecodeTexto(const ALinha: string): string;

function PongEncodeEstado(const AEstado: TPongEstado;
  const AApelido0, AApelido1: string): string;
procedure PongDecodeEstado(const ALinha: string; out AEstado: TPongEstado;
  out AApelido0, AApelido1: string);

/// Token aleatorio de reconexao. Nao e' credencial de seguranca: identidade de
/// verdade e' assunto do ChatSeguro/EchoSeguro (mTLS).
function PongNovoToken: string;

implementation

const
  KIND_NAMES: array[TPongMsgKind] of string = (
    'OI', 'ENTRADA', 'ACEITO', 'RECUSADO', 'AVISO', 'ESTADO');

  SEP_CAMPO = '|';

  // Fator do ponto fixo (ver cabecalho).
  ESCALA = 100;

function ProximoToken(var AText: string; const ASep: string): string;
var
  LPos: Integer;
begin
  LPos := Pos(ASep, AText);
  if LPos = 0 then
  begin
    Result := AText;
    AText := '';
  end
  else
  begin
    Result := Copy(AText, 1, LPos - 1);
    Delete(AText, 1, LPos + Length(ASep) - 1);
  end;
end;

function CorpoDe(const ALinha: string): string;
begin
  Result := ALinha;
  ProximoToken(Result, SEP_CAMPO);
end;

function Sanear(const AValor: string): string;
begin
  Result := StringReplace(AValor, SEP_CAMPO, ' ', [rfReplaceAll]);
end;

function FixoDe(AValor: Double): string;
begin
  Result := IntToStr(Round(AValor * ESCALA));
end;

function DeFixo(const ATexto: string): Double;
begin
  Result := StrToInt64(ATexto) / ESCALA;
end;

function PongMsgKindOf(const ALinha: string): TPongMsgKind;
var
  LResto, LToken: string;
  LKind: TPongMsgKind;
begin
  LResto := ALinha;
  LToken := ProximoToken(LResto, SEP_CAMPO);
  for LKind := Low(TPongMsgKind) to High(TPongMsgKind) do
    if SameText(KIND_NAMES[LKind], LToken) then
    begin
      Result := LKind;
      Exit;
    end;
  raise EPongProtocolo.CreateFmt('mensagem desconhecida: "%s"', [ALinha]);
end;

function PongEncodeOi(const AToken, AApelido: string): string;
begin
  Result := KIND_NAMES[pmkOi] + SEP_CAMPO + Sanear(AToken) +
    SEP_CAMPO + Sanear(AApelido);
end;

procedure PongDecodeOi(const ALinha: string; out AToken, AApelido: string);
var
  LResto: string;
begin
  LResto := CorpoDe(ALinha);
  AToken := ProximoToken(LResto, SEP_CAMPO);
  AApelido := ProximoToken(LResto, SEP_CAMPO);
  if AToken = '' then
    raise EPongProtocolo.Create('OI sem token');
  if AApelido = '' then
    AApelido := 'convidado';
end;

function PongEncodeEntrada(ADirecao: Integer): string;
begin
  Result := KIND_NAMES[pmkEntrada] + SEP_CAMPO + IntToStr(ADirecao);
end;

function PongDecodeEntrada(const ALinha: string): Integer;
var
  LResto: string;
begin
  LResto := CorpoDe(ALinha);
  Result := StrToInt(ProximoToken(LResto, SEP_CAMPO));
  // A direcao vem de outro processo: normalizar aqui evita que um cliente
  // (com bug ou nao) mande 50 e ande 50x mais rapido que todo mundo.
  if Result > 0 then
    Result := 1
  else if Result < 0 then
    Result := -1;
end;

function PongEncodeAceito(AIndice: Integer): string;
begin
  Result := KIND_NAMES[pmkAceito] + SEP_CAMPO + IntToStr(AIndice);
end;

function PongDecodeAceito(const ALinha: string): Integer;
var
  LResto: string;
begin
  LResto := CorpoDe(ALinha);
  Result := StrToInt(ProximoToken(LResto, SEP_CAMPO));
end;

function PongEncodeRecusado(const AMotivo: string): string;
begin
  Result := KIND_NAMES[pmkRecusado] + SEP_CAMPO + Sanear(AMotivo);
end;

function PongEncodeAviso(const ATexto: string): string;
begin
  Result := KIND_NAMES[pmkAviso] + SEP_CAMPO + Sanear(ATexto);
end;

function PongDecodeTexto(const ALinha: string): string;
var
  LResto: string;
begin
  LResto := CorpoDe(ALinha);
  Result := ProximoToken(LResto, SEP_CAMPO);
end;

function PongEncodeEstado(const AEstado: TPongEstado;
  const AApelido0, AApelido1: string): string;
begin
  Result := KIND_NAMES[pmkEstado] + SEP_CAMPO +
    IntToStr(AEstado.Tick) + SEP_CAMPO +
    IntToStr(Ord(AEstado.Fase)) + SEP_CAMPO +
    IntToStr(AEstado.EsperaMs) + SEP_CAMPO +
    FixoDe(AEstado.BolaX) + SEP_CAMPO +
    FixoDe(AEstado.BolaY) + SEP_CAMPO +
    FixoDe(AEstado.VelX) + SEP_CAMPO +
    FixoDe(AEstado.VelY) + SEP_CAMPO +
    FixoDe(AEstado.RaqueteY[0]) + SEP_CAMPO +
    FixoDe(AEstado.RaqueteY[1]) + SEP_CAMPO +
    IntToStr(AEstado.Entrada[0]) + SEP_CAMPO +
    IntToStr(AEstado.Entrada[1]) + SEP_CAMPO +
    IntToStr(AEstado.Placar[0]) + SEP_CAMPO +
    IntToStr(AEstado.Placar[1]) + SEP_CAMPO +
    Sanear(AApelido0) + SEP_CAMPO +
    Sanear(AApelido1);
end;

procedure PongDecodeEstado(const ALinha: string; out AEstado: TPongEstado;
  out AApelido0, AApelido1: string);
var
  LResto: string;
  LFase: Integer;
begin
  LResto := CorpoDe(ALinha);
  AEstado.Tick := StrToInt64(ProximoToken(LResto, SEP_CAMPO));

  LFase := StrToInt(ProximoToken(LResto, SEP_CAMPO));
  if (LFase < Ord(Low(TPongFase))) or (LFase > Ord(High(TPongFase))) then
    raise EPongProtocolo.CreateFmt('fase invalida: %d', [LFase]);
  AEstado.Fase := TPongFase(LFase);

  AEstado.EsperaMs := StrToInt(ProximoToken(LResto, SEP_CAMPO));
  AEstado.BolaX := DeFixo(ProximoToken(LResto, SEP_CAMPO));
  AEstado.BolaY := DeFixo(ProximoToken(LResto, SEP_CAMPO));
  AEstado.VelX := DeFixo(ProximoToken(LResto, SEP_CAMPO));
  AEstado.VelY := DeFixo(ProximoToken(LResto, SEP_CAMPO));
  AEstado.RaqueteY[0] := DeFixo(ProximoToken(LResto, SEP_CAMPO));
  AEstado.RaqueteY[1] := DeFixo(ProximoToken(LResto, SEP_CAMPO));
  AEstado.Entrada[0] := StrToInt(ProximoToken(LResto, SEP_CAMPO));
  AEstado.Entrada[1] := StrToInt(ProximoToken(LResto, SEP_CAMPO));
  AEstado.Placar[0] := StrToInt(ProximoToken(LResto, SEP_CAMPO));
  AEstado.Placar[1] := StrToInt(ProximoToken(LResto, SEP_CAMPO));
  AApelido0 := ProximoToken(LResto, SEP_CAMPO);
  AApelido1 := ProximoToken(LResto, SEP_CAMPO);
end;

function PongNovoToken: string;
var
  LGuid: TGUID;
begin
  if CreateGUID(LGuid) <> 0 then
  begin
    Result := 'tk' + IntToHex(Random(MaxInt), 8);
    Exit;
  end;
  Result := GUIDToString(LGuid);
  Result := StringReplace(Result, '{', '', [rfReplaceAll]);
  Result := StringReplace(Result, '}', '', [rfReplaceAll]);
  Result := StringReplace(Result, '-', '', [rfReplaceAll]);
end;

end.
