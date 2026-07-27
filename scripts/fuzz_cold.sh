#!/usr/bin/env bash
# M22: hunt for cold-vs-hot divergence with long random op streams over many
# seeds. The in-suite test runs one short stream for CI; this is the deep run.
set -u
# derive the module list from the Makefile: a hardcoded copy silently rotted
# when new modules landed, and a compile error then looked like a divergence
MODS=$(grep -m1 -o 'machin test [^|]*tests/' Makefile | sed 's/machin test //; s/tests\///')
OPS="${1:-1500}"
SEEDS="${2:-8}"
fails=0
for s in $(seq 1 "$SEEDS"); do
  seed=$((s * 7919 + 13))
  out=$(GRANGE_DIFF_OPS="$OPS" GRANGE_DIFF_SEED="$seed" machin test $MODS tests/diff_cold_test.src 2>&1)
  if echo "$out" | grep -q "failed=0"; then
    echo "seed $seed: ok ($OPS ops)"
  else
    echo "seed $seed: FAIL"
    echo "$out" | grep -E "DIVERGENCE|FAIL" | head -5
    fails=$((fails + 1))
  fi
done
[ "$fails" -eq 0 ] && echo '{"ok":true,"seeds":'"$SEEDS"',"ops":'"$OPS"'}' || { echo '{"ok":false,"failed_seeds":'"$fails"'}'; exit 1; }
