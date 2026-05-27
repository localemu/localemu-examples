# 11-cognito-demo

End-to-end scripted walkthrough of the LocalEmu Cognito emulator:

1. Create a user pool
2. Create a user pool client
3. Create user `alice`
4. Set a permanent password
5. Sign in with `admin-initiate-auth`
6. Fetch the pool's JWKS endpoint (RSA public key)
7. Fetch the OIDC discovery document
8. Cryptographically verify the returned ID token with PyJWT + the JWKS key
9. Create a group, add `alice`, list her groups
10. List users, confirm `alice` is `CONFIRMED`

Every step prints its real output. Run `teardown.sh` when done.

## Layout

```
11-cognito-demo/
├── src/verify_token.py    # fetches JWKS, verifies RS256 signature
├── scripts/{demo,teardown}.sh
└── requirements.txt
```

## Running

```sh
localemu start                    # in another terminal
pip install -r requirements.txt
./scripts/demo.sh
./scripts/teardown.sh
```
