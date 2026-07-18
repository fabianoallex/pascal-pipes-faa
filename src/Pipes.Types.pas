unit Pipes.Types;

{$I pipes.inc}

{ Tipos publicos compartilhados da biblioteca: identificador de conexao,
  assinaturas de eventos (sempre 'procedure of object' - compat FPC),
  excecoes e o modo de despacho dos callbacks de usuario.

  A API publica trafega TBytes; texto e' convertido internamente como UTF-8
  (ver PipeUtf8Encode/PipeUtf8Decode em Pipes.Framing). }

interface

uses
  SysUtils;

type
  /// Identifica uma conexao no servidor (sequencial atomico; 0 = invalido).
  /// No cliente ha uma unica conexao e o id e' apenas informativo.
  TPipeConnectionId = UInt64;

  { Onde os eventos do usuario executam:
    - pdmPool: pool de threads compartilhado (padrao; paralelismo entre
      conexoes, sem garantia de ordem global).
    - pdmSerialized: pool dedicado de 1 worker (ordem FIFO global garantida).
    - pdmMainThread: TThread.Queue para a main thread (apps VCL/LCL consomem
      eventos sem Synchronize manual; nao usar em apps console sem loop de
      mensagens, pois os eventos nunca seriam drenados). }
  TPipeDispatchMode = (pdmPool, pdmSerialized, pdmMainThread);

  { Qual transporte carrega os frames. Nomeado por ALCANCE, nao por mecanismo:
    - ptLocal: o melhor IPC local do SO (padrao). Named Pipe no Windows, Unix
      Domain Socket no POSIX — por isso 'ptNamedPipe' seria um nome errado
      metade das vezes. Address e' o nome do pipe ('MeuPipe') ou um caminho
      nativo ('\\.\pipe\X', '/tmp/x.sock').
    - ptTcp: socket TCP, identico nas duas plataformas. Address e' 'host:porta'
      ('0.0.0.0:5000', '127.0.0.1:5000', '[::1]:5000').
    Diferente de ptLocal, ptTcp NAO herda controle de acesso do SO: o listener
    fica exposto a rede e a autenticacao e' responsabilidade da aplicacao. }
  TPipeTransport = (ptLocal, ptTcp);

  TPipeMessageEvent = procedure(Sender: TObject; AConnId: TPipeConnectionId;
    const AData: TBytes) of object;
  /// Request-reply no servidor: o retorno em AReply vira o frame de resposta
  /// (enviado pelo proprio worker ao fim do handler, com o mesmo corrId).
  TPipeRequestEvent = procedure(Sender: TObject; AConnId: TPipeConnectionId;
    const ARequest: TBytes; out AReply: TBytes) of object;
  TPipeConnectionEvent = procedure(Sender: TObject;
    AConnId: TPipeConnectionId) of object;
  TPipeErrorEvent = procedure(Sender: TObject; AConnId: TPipeConnectionId;
    const AError: string) of object;

  /// Erro generico da biblioteca (base das demais).
  EPipeError = class(Exception);
  /// Pipe/conexao encerrada (EOF do outro lado, handle/fd fechado).
  EPipeClosed = class(EPipeError);
  /// Connect/Request estourou o prazo.
  EPipeTimeout = class(EPipeError);
  /// Violacao do wire format: magic invalido, kind desconhecido ou payload
  /// acima do maximo configurado.
  EPipeProtocol = class(EPipeError);

const
  PIPE_INVALID_CONNECTION = TPipeConnectionId(0);
  /// Teto padrao de payload por mensagem (protecao contra frame corrompido
  /// ou malicioso); ajustavel por instancia via MaxMessageSize.
  PIPES_DEFAULT_MAX_MESSAGE_SIZE = 16 * 1024 * 1024;
  /// Ociosidade (segundos) antes do primeiro probe de keepalive em ptTcp.
  /// 20s e' deliberadamente curto: o alvo sao conexoes sobre VPN/NAT, cujo
  /// timeout de ociosidade costuma ficar entre 30s e poucos minutos — o probe
  /// precisa acontecer ANTES disso para manter o mapeamento vivo. Ignorado por
  /// ptLocal. Ajustavel por instancia via KeepAliveSeconds (0 = desligado).
  PIPES_DEFAULT_KEEPALIVE_SECONDS = 20;
  /// Intervalo entre probes e quantos probes sem resposta derrubam a conexao.
  /// Com os padroes: par morto detectado em ~20 + 3*5 = 35s.
  PIPES_KEEPALIVE_INTERVAL_SECONDS = 5;
  PIPES_KEEPALIVE_PROBE_COUNT = 3;

implementation

end.
