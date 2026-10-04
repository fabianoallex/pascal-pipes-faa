#!/bin/sh
# Compila e roda as suites FPCUnit (unitaria e de integracao) no FPC 3.2.2 do
# Linux, dentro de um container Docker, com heaptrc. Criterio: 0 erros,
# 0 falhas, "0 unfreed memory blocks" e nenhuma linha "FINALIZATION CHECK
# FAILED" (ver tests/Unit/Pipes.FinalizationCheck.pas), em TODAS as rodadas.
#
# O repositorio e' montado somente-leitura e copiado dentro do container: nada
# e' escrito na arvore de trabalho. Sem Lazarus: o runner FPCUnit so' puxa a
# LCL no Windows. A pascal-common-faa vem do submodulo external/ (checkout sem
# --recursive basta; ela nao precisa do submodulo dela).
#
# Variaveis:
#   FPC_IMAGE  imagem com FPC 3.2.2 no PATH (padrao: fpc322-bookworm).
#   SUITES     "unit", "integration" ou "unit integration" (padrao: as duas).
#   RUNS       quantas vezes rodar cada suite no mesmo container (padrao: 1).
#   FPCOPT     opcoes extras do fpc, ex.: -dPIPES_OPENSSL (no POSIX o ptTls e'
#              opt-in; sem isso a suite TPipeTlsTests nao e' registrada).
#   CPUS       limite de CPU do container (docker --cpus), ex.: 1. Com varios
#              containers ao mesmo tempo e CPUS=1 e' como as corridas de
#              concorrencia aparecem (mesma pratica da pascal-common-faa).
#
# Nota: no Linux o heaptrc so' escreve o resumo com um arquivo de log
# (HEAPTRC=log=...).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${FPC_IMAGE:-fpc322-bookworm}"
SUITES="${SUITES:-unit integration}"
RUNS="${RUNS:-1}"
MOUNT="$ROOT"
command -v cygpath >/dev/null 2>&1 && MOUNT="$(cygpath -w "$ROOT")"
CPUFLAG=""
[ -n "$CPUS" ] && CPUFLAG="--cpus=$CPUS"

[ -f "$ROOT/external/pascal-common-faa/src/PascalCommon.ThreadPool.pas" ] \
  || { echo "external/pascal-common-faa vazio: git submodule update --init external/pascal-common-faa"; exit 1; }

MSYS_NO_PATHCONV=1 docker run --rm $CPUFLAG -e SUITES="$SUITES" -e RUNS="$RUNS" -e FPCOPT="$FPCOPT" \
  -v "$MOUNT:/src:ro" "$IMAGE" sh -c '
  set -e
  mkdir -p /t/external /t/u /t/i && cp -r /src/src /src/tests /t/
  cp -r /src/external/pascal-common-faa /t/external/
  C=/t/external/pascal-common-faa/src
  FAIL=0
  for S in $SUITES; do
    case $S in
      unit) D=/t/tests/Unit/fpc; P=PipesUnitTestsFpc; U=/t/u ;;
      integration) D=/t/tests/Integration/fpc; P=PipesIntegrationTestsFpc; U=/t/i ;;
      *) echo "suite desconhecida: $S"; exit 2 ;;
    esac
    cd $D
    fpc -v0 -Mdelphi $FPCOPT -Fu/t/src -Fi/t/src -Fu$C -Fi$C -FU$U -gh -gl -o$U/runner $P.lpr > $U/build.log 2>&1 \
      || { grep -iE "error|fatal" $U/build.log | head -30; exit 1; }
    N=1
    while [ $N -le $RUNS ]; do
      # Os testes de TLS procuram tests/pki subindo a partir do executavel
      # (/t/i -> /t), por isso o runner fica num irmao de /t/tests.
      HEAPTRC="log=$U/heap.txt" $U/runner --all --format=plain > $U/run.log 2>&1 || true
      T=$(grep -E "^Number of run tests" $U/run.log | grep -oE "[0-9]+" || echo "?")
      OK=1
      grep -qE "^Number of errors: +0$" $U/run.log || OK=0
      grep -qE "^Number of failures: +0$" $U/run.log || OK=0
      grep -qE "^0 unfreed memory blocks" $U/heap.txt || OK=0
      ! grep -q "FINALIZATION CHECK FAILED" $U/run.log || OK=0
      if [ $OK = 1 ]; then
        echo "$S rodada $N: ok ($T testes, 0 vazamentos)"
      else
        FAIL=1
        echo "$S rodada $N: FALHOU"
        grep -E "^Number of|FINALIZATION CHECK FAILED" $U/run.log || true
        grep "unfreed" $U/heap.txt || true
        grep -B1 -A3 "Message:" $U/run.log | head -40 || true
      fi
      N=$((N + 1))
    done
  done
  exit $FAIL'
