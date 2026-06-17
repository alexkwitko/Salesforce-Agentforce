#!/usr/bin/env bash
# Run the Kwitko multi-turn use-case suite N times and tally per-case pass rate.
# A case is CERTIFIED only at 100% across N runs (LLM output is non-deterministic).
#
# Usage: tools/run_multiturn_eval.sh [N] [ORG] [ONLY]
#   tools/run_multiturn_eval.sh 10 AgentforceDev          # all cases x10
#   tools/run_multiturn_eval.sh 10 AgentforceDev A        # category A x10
#   tools/run_multiturn_eval.sh 10 AgentforceDev A2       # one case x10
set -uo pipefail
N="${1:-10}"; ORG="${2:-AgentforceDev}"; AGENT="${3:-Kwitko_Concierge_Web}"; ONLY="${4:-}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
SPEC="/tmp/kwitko_mt_$$.json"

python3 "$DIR/tools/agent_multiturn_cases.py" --org "$ORG" --agent "$AGENT" --out "$SPEC" ${ONLY:+--only "$ONLY"} || exit 1
echo "AGENT: $AGENT"
echo "Running $N iterations against $ORG ..."

# ordered case names from the spec (results come back positional: test-0, test-1, ...)
NAMES="/tmp/kwitko_names_$$.txt"
python3 -c "import json;[print(t['name']) for t in json.load(open('$SPEC'))['tests']]" > "$NAMES"

TALLY="/tmp/kwitko_tally_$$.txt"; : > "$TALLY"
for i in $(seq 1 "$N"); do
  sf agent test run-eval --spec "$SPEC" --target-org "$ORG" --result-format json 2>/dev/null \
    | python3 -c "
import sys,json
names=[l.strip() for l in open('$NAMES')]
raw=sys.stdin.read(); k=raw.find('{')
if k<0: sys.exit()
try: d=json.loads(raw[k:])
except: sys.exit()
res=(d.get('result',d) if isinstance(d,dict) else {})
res=res.get('results') if isinstance(res,dict) else None
res=res or d.get('results') or []
for idx,t in enumerate(res):
    nm=names[idx] if idx<len(names) else t.get('id','?')
    rating=None
    for e in t.get('evaluation_results',[]):
        if e.get('type')=='evaluator.bot_response_rating':
            rating=e.get('is_pass')
    print(f'{nm}\t{rating}')
" >> "$TALLY"
  echo "  run $i done"
done

echo ""
echo "=== PER-CASE PASS RATE (out of $N) ==="
python3 -c "
import collections
tot=collections.Counter(); ok=collections.Counter()
for line in open('$TALLY'):
    p=line.rstrip('\n').split('\t')
    if len(p)<2: continue
    nm,res=p[0],p[1]
    tot[nm]+=1
    if str(res).upper() in ('TRUE','PASS','PASSED'): ok[nm]+=1
for nm in sorted(tot):
    mark='✅' if ok[nm]==tot[nm] else '❌'
    print(f'  {mark} {ok[nm]}/{tot[nm]}  {nm}')
if not tot: print('  (no parsed results — run with --result-format human to debug)')
"
rm -f "$SPEC" "$TALLY" "$NAMES"
