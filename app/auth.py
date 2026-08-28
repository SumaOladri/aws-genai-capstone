import logging
import os
from functools import lru_cache

import boto3
import httpx
from jose import jwt

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = os.environ.get("AWS_REGION_NAME", "us-east-1")
COGNITO_DOMAIN = os.environ.get("COGNITO_DOMAIN", "")
CLIENT_ID = os.environ.get("COGNITO_CLIENT_ID", "")
USER_POOL_ID = os.environ.get("COGNITO_USER_POOL_ID", "")
SECRET_PARAM = os.environ.get("COGNITO_SECRET_PARAM", "")
APP_BASE_URL = os.environ.get("APP_BASE_URL", "http://127.0.0.1:8000")

ISSUER = f"https://cognito-idp.{REGION}.amazonaws.com/{USER_POOL_ID}"
REDIRECT_URI = f"{APP_BASE_URL}/callback"


@lru_cache(maxsize=1)
def client_secret() -> str:
    """Fetch the Cognito client secret from Parameter Store, once per container."""
    ssm = boto3.client("ssm", region_name=REGION)
    response = ssm.get_parameter(Name=SECRET_PARAM, WithDecryption=True)
    return response["Parameter"]["Value"]


@lru_cache(maxsize=1)
def jwks() -> dict:
    """Fetch Cognito's public signing keys, once per container."""
    url = f"{ISSUER}/.well-known/jwks.json"
    return httpx.get(url, timeout=10).json()


def login_url() -> str:
    """Where to send an unauthenticated visitor."""
    return (
        f"{COGNITO_DOMAIN}/login"
        f"?client_id={CLIENT_ID}"
        f"&response_type=code"
        f"&scope=email+openid+profile"
        f"&redirect_uri={REDIRECT_URI}"
    )


def logout_url() -> str:
    """Where to send a user who is signing out."""
    return (
        f"{COGNITO_DOMAIN}/logout"
        f"?client_id={CLIENT_ID}"
        f"&logout_uri={APP_BASE_URL}/"
    )


def exchange_code(code: str) -> dict:
    """Swap the one-time auth code for tokens."""
    response = httpx.post(
        f"{COGNITO_DOMAIN}/oauth2/token",
        data={
            "grant_type": "authorization_code",
            "client_id": CLIENT_ID,
            "code": code,
            "redirect_uri": REDIRECT_URI,
        },
        auth=(CLIENT_ID, client_secret()),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        timeout=10,
    )
    response.raise_for_status()
    return response.json()


def verify_token(token: str, access_token: str | None = None) -> dict | None:
    """Validate an ID token's signature, issuer, audience and at_hash.

    Cognito ID tokens carry an at_hash claim binding them to the matching
    access token, so the access token must be supplied for that check.
    """
    try:
        header = jwt.get_unverified_header(token)
        key = next(
            (k for k in jwks()["keys"] if k["kid"] == header["kid"]), None
        )
        if key is None:
            logger.error("No matching JWKS key for kid=%s", header.get("kid"))
            return None

        claims = jwt.decode(
            token,
            key,
            algorithms=["RS256"],
            audience=CLIENT_ID,
            issuer=ISSUER,
            access_token=access_token,
        )
        logger.info("Token verified for %s", claims.get("email"))
        return claims
    except Exception as exc:
        logger.error("Token verification failed: %s: %s", type(exc).__name__, exc)
        return None