"""Verify a Cognito-signed JWT against the pool's JWKS endpoint.

Usage: python verify_token.py <pool_id> <client_id>

Authenticates the test user (alice) with admin-initiate-auth, fetches the
pool's RSA public key from /.well-known/jwks.json, and verifies the
RS256 signature with PyJWT. The output prints the decoded claims.
"""
from __future__ import annotations

import sys

import boto3
import jwt as pyjwt
import requests
from jwt import PyJWK

LOCALEMU = "http://localhost:4566"


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: verify_token.py <pool_id> <client_id>", file=sys.stderr)
        return 2

    pool_id, client_id = sys.argv[1], sys.argv[2]

    client = boto3.client(
        "cognito-idp",
        endpoint_url=LOCALEMU,
        region_name="us-east-1",
        aws_access_key_id="AKIAIOSFODNN7EXAMPLE",
        aws_secret_access_key="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    )

    result = client.admin_initiate_auth(
        UserPoolId=pool_id,
        ClientId=client_id,
        AuthFlow="ADMIN_USER_PASSWORD_AUTH",
        AuthParameters={"USERNAME": "alice", "PASSWORD": "MySecret123!"},
    )
    id_token = result["AuthenticationResult"]["IdToken"]

    jwks_url = f"{LOCALEMU}/{pool_id}/.well-known/jwks.json"
    jwks = requests.get(jwks_url, timeout=5).json()
    print(f"JWKS keys: {len(jwks['keys'])}")

    header = pyjwt.get_unverified_header(id_token)
    print(f"Token kid: {header['kid']}")
    print(f"Token alg: {header['alg']}")

    decoded = None
    for key_data in jwks["keys"]:
        if key_data["kid"] == header["kid"]:
            jwk_key = PyJWK.from_dict(key_data)
            decoded = pyjwt.decode(
                id_token,
                jwk_key,
                algorithms=["RS256"],
                audience=client_id,
            )
            print("\nVERIFIED! Token claims:")
            print(f"  sub:              {decoded['sub']}")
            print(f"  email:            {decoded.get('email')}")
            print(f"  cognito:username: {decoded['cognito:username']}")
            print(f"  token_use:        {decoded['token_use']}")
            print(f"  iss:              {decoded['iss']}")
            break

    if decoded is None:
        print("ERROR: no matching key in JWKS", file=sys.stderr)
        return 1

    oidc_url = f"{LOCALEMU}/{pool_id}/.well-known/openid-configuration"
    oidc = requests.get(oidc_url, timeout=5).json()
    print(f"\nOIDC issuer:             {oidc['issuer']}")
    print(f"Issuer matches token:    {oidc['issuer'] == decoded['iss']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
