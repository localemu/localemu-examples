#!/usr/bin/env bash
# Full Cognito walkthrough: create a user pool, a client, a user, sign in,
# fetch JWKS, verify a JWT, manage groups, list users. Each step prints its
# output. Run `./scripts/teardown.sh` to remove everything.
set -euo pipefail

export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
export AWS_DEFAULT_REGION=us-east-1
ENDPOINT="--endpoint-url=http://localhost:4566"

HERE="$(cd "$(dirname "$0")/.." && pwd)"

bold() { printf "\n\033[1;36m== %s ==\033[0m\n" "$1"; }

bold "1. Create user pool"
POOL_ID=$(aws $ENDPOINT cognito-idp create-user-pool \
  --pool-name my-app-pool \
  --query 'UserPool.Id' --output text)
echo "POOL_ID=$POOL_ID"

bold "2. Create user pool client"
CLIENT_ID=$(aws $ENDPOINT cognito-idp create-user-pool-client \
  --user-pool-id "$POOL_ID" \
  --client-name my-app \
  --explicit-auth-flows ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH ALLOW_ADMIN_USER_PASSWORD_AUTH \
  --query 'UserPoolClient.ClientId' --output text)
echo "CLIENT_ID=$CLIENT_ID"

bold "3. Create user alice (FORCE_CHANGE_PASSWORD status)"
aws $ENDPOINT cognito-idp admin-create-user \
  --user-pool-id "$POOL_ID" \
  --username alice \
  --user-attributes Name=email,Value=alice@example.com \
  --temporary-password 'TempPass123!' \
  --query 'User.{Username:Username,Status:UserStatus}'

bold "4. Set permanent password"
aws $ENDPOINT cognito-idp admin-set-user-password \
  --user-pool-id "$POOL_ID" \
  --username alice \
  --password 'MySecret123!' \
  --permanent
echo "password set, user should now be CONFIRMED"

bold "5. Sign in with admin-initiate-auth (truncated tokens)"
TOKENS_JSON=$(aws $ENDPOINT cognito-idp admin-initiate-auth \
  --user-pool-id "$POOL_ID" \
  --client-id "$CLIENT_ID" \
  --auth-flow ADMIN_USER_PASSWORD_AUTH \
  --auth-parameters USERNAME=alice,PASSWORD='MySecret123!')
python3 -c "
import json, sys
r = json.loads(sys.argv[1])['AuthenticationResult']
print(f'  TokenType:    {r[\"TokenType\"]}')
print(f'  ExpiresIn:    {r[\"ExpiresIn\"]}')
print(f'  IdToken:      {r[\"IdToken\"][:60]}...')
print(f'  AccessToken:  {r[\"AccessToken\"][:60]}...')
print(f'  RefreshToken: {r[\"RefreshToken\"][:40]}...')
" "$TOKENS_JSON"

bold "6. Fetch JWKS endpoint"
curl -s "http://localhost:4566/$POOL_ID/.well-known/jwks.json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
k = data['keys'][0]
print(f'  kty:   {k[\"kty\"]}')
print(f'  alg:   {k[\"alg\"]}')
print(f'  kid:   {k[\"kid\"]}')
print(f'  n:     {k[\"n\"][:50]}... (truncated)')
print(f'  keys in set: {len(data[\"keys\"])}')
"

bold "7. Fetch OIDC discovery"
curl -s "http://localhost:4566/$POOL_ID/.well-known/openid-configuration" | python3 -c "
import json, sys
oidc = json.load(sys.stdin)
for k in ('issuer', 'jwks_uri', 'authorization_endpoint', 'token_endpoint'):
    print(f'  {k}: {oidc[k]}')
print(f'  id_token_signing_alg_values_supported: {oidc[\"id_token_signing_alg_values_supported\"]}')
"

bold "8. Verify the JWT (Python + PyJWT + RSA public key from JWKS)"
python3 "$HERE/src/verify_token.py" "$POOL_ID" "$CLIENT_ID"

bold "9. Create admins group, add alice, list her groups"
aws $ENDPOINT cognito-idp create-group \
  --user-pool-id "$POOL_ID" \
  --group-name admins \
  --description "Admin users" \
  --query 'Group.{GroupName:GroupName,Description:Description}'
aws $ENDPOINT cognito-idp admin-add-user-to-group \
  --user-pool-id "$POOL_ID" \
  --username alice \
  --group-name admins
aws $ENDPOINT cognito-idp admin-list-groups-for-user \
  --user-pool-id "$POOL_ID" \
  --username alice \
  --query 'Groups[].[GroupName,Description]' --output table

bold "10. List users (alice should be CONFIRMED)"
aws $ENDPOINT cognito-idp list-users \
  --user-pool-id "$POOL_ID" \
  --query 'Users[].[Username,UserStatus]' --output table

# Persist IDs so teardown knows what to remove
echo "$POOL_ID" > "$HERE/.pool_id"
echo
echo "→ demo complete. pool + client + user live in LocalEmu until you run teardown."
echo "→ POOL_ID saved to .pool_id for teardown.sh to pick up."
