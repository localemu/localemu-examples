#!/usr/bin/env bash
# Step 03: mutation loop. For each Sid in the golden policy, create a
# mutant policy with that Sid removed, attach it to the role, invoke
# the Lambda, and assert it fails with AccessDenied on exactly the
# expected action.
#
# The two assertions per mutant together prove the golden policy is
# minimum-viable:
#   (a) removing the Sid breaks something       -> Sid is justified
#   (b) it breaks the expected action, not another -> no covert over-privilege
#
# Total: 6 mutations, each must deny exactly its matching action.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

need_healthy_localemu
state_load
: "${FN:?run infra/01_setup.sh first}"
[[ -f "${STATE_DIR}/golden.json" ]] || fail "run infra/02_baseline.sh first (golden.json missing)"

bold "6. Mutation loop: remove each Sid, expect its action to be denied"

# Sid → expected denied action. This is the contract the handler and
# the golden policy share: step N's action is authorized by Sid N.
MATRIX=(
  "GetConfig  s3:GetObject"
  "DecryptKms kms:Decrypt"
  "ReadParam  ssm:GetParameter"
  "ReadSecret secretsmanager:GetSecretValue"
  "WriteEvent dynamodb:PutItem"
  "Notify     sns:Publish"
)

PASS=0
FAIL=0

for row in "${MATRIX[@]}"; do
  sid="${row%% *}"
  expected="${row##* }"

  log "Mutant: remove Sid '${sid}', expect denied_action == '${expected}'"

  mutant=$(python3 -c "
import json, sys
pol = json.load(open('${STATE_DIR}/golden.json'))
pol['Statement'] = [s for s in pol['Statement'] if s.get('Sid') != '${sid}']
print(json.dumps(pol))
")

  awsx iam put-role-policy --role-name "${ROLE}" \
    --policy-name mutation-test-policy \
    --policy-document "${mutant}" >/dev/null

  response=$(invoke_lambda "${FN}" "{\"request_id\":\"mut-${sid}\"}")

  status=$(printf '%s' "${response}" \
    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("status",""))')
  denied=$(printf '%s' "${response}" \
    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("denied_action",""))')

  if [[ "${status}" == "forbidden" && "${denied}" == "${expected}" ]]; then
    ok "  denied_action=${denied}  (as expected)"
    PASS=$((PASS + 1))
  else
    warn "  FAIL: status=${status} denied_action=${denied}"
    warn "  full response: ${response}"
    FAIL=$((FAIL + 1))
  fi
done

bold "7. Result"

log "Restoring the golden policy so the role ends the demo in a working state"
awsx iam put-role-policy --role-name "${ROLE}" \
  --policy-name mutation-test-policy \
  --policy-document "file://${STATE_DIR}/golden.json" >/dev/null
ok "Golden restored"

echo
if (( FAIL == 0 )); then
  _color '32' "  🎉  All ${PASS}/6 mutations denied exactly the expected action."
  _color '32' "       Golden policy is provably minimum-viable."
else
  _color '31' "  ✗  ${FAIL}/6 mutations failed their assertion."
  exit 1
fi
