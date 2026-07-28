unit Jogo.Protocolo;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

{ Contrato de mensagens do Pontos e Caixas em rede. Unit pura: depende das
  regras (Jogo.Partida) mas NAO da biblioteca de pipes — quem converte para
  TBytes e' o form, com SendText/BroadcastText.

  Formato de fio: uma linha de texto UTF-8 por mensagem, "KIND|campo|campo".

  Quem fala o que:

    CONVIDADO -> HOSPEDEIRO
      OI|token|apelido      identifica-se. E' a PRIMEIRA coisa que o convidado
                            manda depois de cada Connect — inclusive depois de
                            uma reconexao automatica, e e' isso que devolve a
                            vaga ao mesmo jogador (ver o token abaixo).
      JOGADA|H|r|c          pede uma jogada. PEDE: quem decide e' o hospedeiro.

    HOSPEDEIRO -> CONVIDADO
      ACEITO|indice         voce entrou, e e' o jogador <indice>.
      RECUSADO|motivo       voce nao entrou, e o motivo e' esse.
      AVISO|texto           recado avulso (jogada recusada, oponente saiu).
      ESTADO|...            o tabuleiro inteiro. Ver abaixo.

  Sobre o token: e' um identificador que o convidado sorteia UMA vez, ao abrir
  o programa, e repete em todo OI. O hospedeiro guarda o token de quem ocupa a
  vaga, entao um convidado que caiu e voltou se reconhece como o mesmo jogador
  e recupera a partida em andamento. Nao e' credencial de seguranca — nao ha
  nada que impeca alguem de repetir o token alheio, e enquanto a vaga esta'
  vazia qualquer token novo tambem entra. Autenticacao de verdade e' o assunto
  do ChatSeguro/EchoSeguro (mTLS, identidade vinda do certificado, verificada
  antes de a aplicacao ver o primeiro byte).

  O ESTADO leva tambem QUAL foi a ultima aresta jogada. Nao e' redundante com
  o tabuleiro: o convidado recebe a posicao pronta e, sem esse campo, nao teria
  como saber o que mudou desde o quadro anterior — que e' justamente o que a
  UI precisa para destacar a jogada do adversario. O campo vai no FIM da linha
  de proposito: o parser devolve '' para campo ausente, entao uma ponta antiga
  continua lendo uma linha nova sem quebrar.

  Sobre o ESTADO ser o tabuleiro INTEIRO a cada jogada, e nao um delta: um
  delta seria menor (uma aresta contra ~60), mas exigiria que os dois lados
  aplicassem a mesma sequencia de eventos, na mesma ordem, sem perder nenhum —
  e uma reconexao no meio da partida quebra exatamente essa premissa. Mandar o
  estado inteiro faz o convidado que acabou de voltar ficar correto pelo mesmo
  caminho de codigo do convidado que nunca caiu. Num tabuleiro 12x12 sao ~2 KB
  por jogada; a troca de bytes por "nao existe divergencia possivel" e' boa
  aqui e continuaria boa em muita aplicacao de negocio. }

interface

uses
  SysUtils,
  Jogo.Partida;

type
  TJogoMsgKind = (
    jmkOi,        // convidado -> hospedeiro
    jmkJogada,    // convidado -> hospedeiro
    jmkAceito,    // hospedeiro -> convidado
    jmkRecusado,  // hospedeiro -> convidado
    jmkAviso,     // hospedeiro -> convidado
    jmkEstado     // hospedeiro -> convidado
  );

  EJogoProtocolo = class(Exception);

/// Le so' o KIND da linha. EJogoProtocolo se a mensagem nao for reconhecida.
function JogoMsgKindOf(const ALinha: string): TJogoMsgKind;

function JogoEncodeOi(const AToken, AApelido: string): string;
procedure JogoDecodeOi(const ALinha: string; out AToken, AApelido: string);

function JogoEncodeJogada(const AAresta: TJogoAresta): string;
function JogoDecodeJogada(const ALinha: string): TJogoAresta;

function JogoEncodeAceito(AIndice: Integer): string;
function JogoDecodeAceito(const ALinha: string): Integer;

function JogoEncodeRecusado(const AMotivo: string): string;
function JogoEncodeAviso(const ATexto: string): string;
/// Texto de RECUSADO e AVISO (mesmo formato: um campo so').
function JogoDecodeTexto(const ALinha: string): string;

/// Serializa a partida inteira (tabuleiro, vez, placar implicito, apelidos).
function JogoEncodeEstado(APartida: TJogoPartida;
  const AApelido0, AApelido1: string): string;
/// Aplica o estado recebido sobre APartida, SEM passar pelas regras: quem
/// recebe e' espelho, nao autoridade. Devolve os apelidos dos dois lados.
procedure JogoDecodeEstado(const ALinha: string; APartida: TJogoPartida;
  out AApelido0, AApelido1: string);

/// Token aleatorio de reconexao. Nao e' segredo criptografico (ver cabecalho).
function JogoNovoToken: string;

implementation

const
  KIND_NAMES: array[TJogoMsgKind] of string = (
    'OI', 'JOGADA', 'ACEITO', 'RECUSADO', 'AVISO', 'ESTADO');

  LADO_NAMES: array[TJogoLado] of string = ('H', 'V');

  SEP_CAMPO = '|';
  SEP_ITEM = ';';
  SEP_SUB = ',';

{ Consome e remove o proximo campo de AText, delimitado por ASep. }
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

{ Remove o KIND do inicio da linha e devolve o resto. }
function CorpoDe(const ALinha: string): string;
begin
  Result := ALinha;
  ProximoToken(Result, SEP_CAMPO);
end;

function LadoFromStr(const AStr: string): TJogoLado;
var
  LLado: TJogoLado;
begin
  for LLado := Low(TJogoLado) to High(TJogoLado) do
    if SameText(LADO_NAMES[LLado], AStr) then
    begin
      Result := LLado;
      Exit;
    end;
  raise EJogoProtocolo.CreateFmt('lado de aresta desconhecido: "%s"', [AStr]);
end;

{ Campos livres (apelido) nao tem escaping de verdade neste sample: os
  separadores viram espaco na entrada para nao quebrar o parser. }
function Sanear(const AValor: string): string;
begin
  Result := StringReplace(AValor, SEP_CAMPO, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, SEP_ITEM, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, SEP_SUB, ' ', [rfReplaceAll]);
end;

function JogoMsgKindOf(const ALinha: string): TJogoMsgKind;
var
  LResto, LToken: string;
  LKind: TJogoMsgKind;
begin
  LResto := ALinha;
  LToken := ProximoToken(LResto, SEP_CAMPO);
  for LKind := Low(TJogoMsgKind) to High(TJogoMsgKind) do
    if SameText(KIND_NAMES[LKind], LToken) then
    begin
      Result := LKind;
      Exit;
    end;
  raise EJogoProtocolo.CreateFmt('mensagem desconhecida: "%s"', [ALinha]);
end;

function JogoEncodeOi(const AToken, AApelido: string): string;
begin
  Result := KIND_NAMES[jmkOi] + SEP_CAMPO + Sanear(AToken) +
    SEP_CAMPO + Sanear(AApelido);
end;

procedure JogoDecodeOi(const ALinha: string; out AToken, AApelido: string);
var
  LResto: string;
begin
  LResto := CorpoDe(ALinha);
  AToken := ProximoToken(LResto, SEP_CAMPO);
  AApelido := ProximoToken(LResto, SEP_CAMPO);
  if AToken = '' then
    raise EJogoProtocolo.Create('OI sem token');
  if AApelido = '' then
    AApelido := 'convidado';
end;

function JogoEncodeJogada(const AAresta: TJogoAresta): string;
begin
  Result := KIND_NAMES[jmkJogada] + SEP_CAMPO + LADO_NAMES[AAresta.Lado] +
    SEP_CAMPO + IntToStr(AAresta.Linha) + SEP_CAMPO + IntToStr(AAresta.Coluna);
end;

function JogoDecodeJogada(const ALinha: string): TJogoAresta;
var
  LResto: string;
begin
  LResto := CorpoDe(ALinha);
  Result.Lado := LadoFromStr(ProximoToken(LResto, SEP_CAMPO));
  Result.Linha := StrToInt(ProximoToken(LResto, SEP_CAMPO));
  Result.Coluna := StrToInt(ProximoToken(LResto, SEP_CAMPO));
end;

function JogoEncodeAceito(AIndice: Integer): string;
begin
  Result := KIND_NAMES[jmkAceito] + SEP_CAMPO + IntToStr(AIndice);
end;

function JogoDecodeAceito(const ALinha: string): Integer;
var
  LResto: string;
begin
  LResto := CorpoDe(ALinha);
  Result := StrToInt(ProximoToken(LResto, SEP_CAMPO));
end;

function JogoEncodeRecusado(const AMotivo: string): string;
begin
  Result := KIND_NAMES[jmkRecusado] + SEP_CAMPO + Sanear(AMotivo);
end;

function JogoEncodeAviso(const ATexto: string): string;
begin
  Result := KIND_NAMES[jmkAviso] + SEP_CAMPO + Sanear(ATexto);
end;

function JogoDecodeTexto(const ALinha: string): string;
var
  LResto: string;
begin
  LResto := CorpoDe(ALinha);
  Result := ProximoToken(LResto, SEP_CAMPO);
end;

function JogoEncodeEstado(APartida: TJogoPartida;
  const AApelido0, AApelido1: string): string;
var
  LTab: TJogoTabuleiro;
  LArestas, LCaixas, LUltima: string;
  LR, LC, LDono: Integer;
  LAresta: TJogoAresta;

  procedure AcumularAresta;
  begin
    LDono := LTab.DonoAresta(LAresta);
    if LDono = JOGO_SEM_DONO then
      Exit;
    if LArestas <> '' then
      LArestas := LArestas + SEP_ITEM;
    LArestas := LArestas + LADO_NAMES[LAresta.Lado] + SEP_SUB +
      IntToStr(LAresta.Linha) + SEP_SUB + IntToStr(LAresta.Coluna) + SEP_SUB +
      IntToStr(LDono);
  end;

begin
  LTab := APartida.Tabuleiro;
  LArestas := '';
  LCaixas := '';

  // So' o que foi jogado entra na linha; o resto e' livre por ausencia.
  for LR := 0 to LTab.Linhas do
    for LC := 0 to LTab.Colunas - 1 do
    begin
      LAresta := JogoAresta(jlHorizontal, LR, LC);
      AcumularAresta;
    end;
  for LR := 0 to LTab.Linhas - 1 do
    for LC := 0 to LTab.Colunas do
    begin
      LAresta := JogoAresta(jlVertical, LR, LC);
      AcumularAresta;
    end;

  for LR := 0 to LTab.Linhas - 1 do
    for LC := 0 to LTab.Colunas - 1 do
    begin
      LDono := LTab.DonoCaixa[LR, LC];
      if LDono = JOGO_SEM_DONO then
        Continue;
      if LCaixas <> '' then
        LCaixas := LCaixas + SEP_ITEM;
      LCaixas := LCaixas + IntToStr(LR) + SEP_SUB + IntToStr(LC) + SEP_SUB +
        IntToStr(LDono);
    end;

  if APartida.TryUltimaJogada(LAresta) then
    LUltima := LADO_NAMES[LAresta.Lado] + SEP_SUB + IntToStr(LAresta.Linha) +
      SEP_SUB + IntToStr(LAresta.Coluna)
  else
    LUltima := ''; // partida recem-comecada: nao ha o que destacar

  Result := KIND_NAMES[jmkEstado] + SEP_CAMPO +
    IntToStr(LTab.Linhas) + SEP_CAMPO +
    IntToStr(LTab.Colunas) + SEP_CAMPO +
    IntToStr(APartida.Vez) + SEP_CAMPO +
    IntToStr(Ord(APartida.Terminada)) + SEP_CAMPO +
    Sanear(AApelido0) + SEP_CAMPO +
    Sanear(AApelido1) + SEP_CAMPO +
    LArestas + SEP_CAMPO +
    LCaixas + SEP_CAMPO +
    LUltima;
end;

procedure JogoDecodeEstado(const ALinha: string; APartida: TJogoPartida;
  out AApelido0, AApelido1: string);
var
  LResto, LArestas, LCaixas, LUltima, LItem, LSub: string;
  LLinhas, LColunas, LVez, LTerminada, LR, LC, LDono: Integer;
  LAresta: TJogoAresta;
begin
  LResto := CorpoDe(ALinha);
  LLinhas := StrToInt(ProximoToken(LResto, SEP_CAMPO));
  LColunas := StrToInt(ProximoToken(LResto, SEP_CAMPO));
  LVez := StrToInt(ProximoToken(LResto, SEP_CAMPO));
  LTerminada := StrToInt(ProximoToken(LResto, SEP_CAMPO));
  AApelido0 := ProximoToken(LResto, SEP_CAMPO);
  AApelido1 := ProximoToken(LResto, SEP_CAMPO);
  LArestas := ProximoToken(LResto, SEP_CAMPO);
  LCaixas := ProximoToken(LResto, SEP_CAMPO);
  LUltima := ProximoToken(LResto, SEP_CAMPO); // '' se a linha nao trouxer

  // Reiniciar sempre: o estado que chega e' completo, entao zerar antes evita
  // que sobre lixo de uma partida anterior (ou de outro tamanho de tabuleiro).
  APartida.Reiniciar(LLinhas, LColunas);

  while LArestas <> '' do
  begin
    LItem := ProximoToken(LArestas, SEP_ITEM);
    if LItem = '' then
      Continue;
    LSub := ProximoToken(LItem, SEP_SUB);
    LAresta.Lado := LadoFromStr(LSub);
    LAresta.Linha := StrToInt(ProximoToken(LItem, SEP_SUB));
    LAresta.Coluna := StrToInt(ProximoToken(LItem, SEP_SUB));
    LDono := StrToInt(ProximoToken(LItem, SEP_SUB));
    APartida.Tabuleiro.DefinirDonoAresta(LAresta, LDono);
  end;

  while LCaixas <> '' do
  begin
    LItem := ProximoToken(LCaixas, SEP_ITEM);
    if LItem = '' then
      Continue;
    LR := StrToInt(ProximoToken(LItem, SEP_SUB));
    LC := StrToInt(ProximoToken(LItem, SEP_SUB));
    LDono := StrToInt(ProximoToken(LItem, SEP_SUB));
    APartida.Tabuleiro.DefinirDonoCaixa(LR, LC, LDono);
  end;

  if LUltima <> '' then
  begin
    LSub := ProximoToken(LUltima, SEP_SUB);
    LAresta.Lado := LadoFromStr(LSub);
    LAresta.Linha := StrToInt(ProximoToken(LUltima, SEP_SUB));
    LAresta.Coluna := StrToInt(ProximoToken(LUltima, SEP_SUB));
    APartida.DefinirUltimaJogada(LAresta);
  end
  else
    // Reiniciar la' em cima ja' limpou, mas ser explicito aqui deixa o
    // "sem ultima jogada" visivel na leitura.
    APartida.LimparUltimaJogada;

  APartida.DefinirVez(LVez);
  APartida.DefinirTerminada(LTerminada <> 0);
  APartida.RecalcularPlacar;
end;

function JogoNovoToken: string;
var
  LGuid: TGUID;
begin
  if CreateGUID(LGuid) <> 0 then
  begin
    // Fallback improvavel: o token so' precisa ser diferente do token do outro
    // jogador na mesma partida.
    Result := 'tk' + IntToHex(Random(MaxInt), 8);
    Exit;
  end;
  Result := GUIDToString(LGuid);
  Result := StringReplace(Result, '{', '', [rfReplaceAll]);
  Result := StringReplace(Result, '}', '', [rfReplaceAll]);
  Result := StringReplace(Result, '-', '', [rfReplaceAll]);
end;

end.
