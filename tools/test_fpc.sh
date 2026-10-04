#!/bin/sh
# Compila (lazbuild) e roda as suites FPCUnit no Windows. Criterio: 0 erros,
# 0 falhas, "0 unfreed memory blocks" (heaptrc, ligado nos .lpi de teste) e
# nenhuma linha "FINALIZATION CHECK FAILED" (ver
# tests/Unit/Pipes.FinalizationCheck.pas). No Linux: tools/test_fpc_docker.sh.
#
# Os .lpi de teste pegam a pascal-common-faa do submodulo external/ (Prefer),
# nao de um pacote registrado no IDE; confira no build.log em caso de duvida.
#
# O lado Delphi nao tem equivalente por linha de comando (o Delphi Community
# Edition nao compila fora do IDE): rode tests\Unit\Pipes.UnitTests.dproj e
# tests\Integration\Pipes.IntegrationTests.dproj pelo IDE.
#
# SUITES: "unit", "integration" ou as duas (padrao).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAZBUILD="${LAZBUILD:-lazbuild}"
command -v "$LAZBUILD" >/dev/null 2>&1 || LAZBUILD=/c/lazarus4.0/lazbuild.exe
SUITES="${SUITES:-unit integration}"

[ -f "$ROOT/external/pascal-common-faa/src/PascalCommon.ThreadPool.pas" ] \
  || { echo "external/pascal-common-faa vazio: git submodule update --init external/pascal-common-faa"; exit 1; }

FAIL=0
for S in $SUITES; do
  case $S in
    unit) D="$ROOT/tests/Unit/fpc"; P=PipesUnitTestsFpc ;;
    integration) D="$ROOT/tests/Integration/fpc"; P=PipesIntegrationTestsFpc ;;
    *) echo "suite desconhecida: $S"; exit 2 ;;
  esac
  cd "$D"
  if ! "$LAZBUILD" -B $P.lpi > build.log 2>&1; then
    grep -E "Error|Fatal" build.log | grep -v "generics\." | head -30
    exit 1
  fi
  ./$P.exe --all --format=plain > run.log 2>&1 || true
  echo "== $S"
  grep -E "^Number of|unfreed|FINALIZATION CHECK FAILED" run.log
  grep -qE "^Number of errors: +0$" run.log && grep -qE "^Number of failures: +0$" run.log \
    && grep -qE "^0 unfreed memory blocks" run.log && ! grep -q "FINALIZATION CHECK FAILED" run.log \
    || FAIL=1
done
exit $FAIL
