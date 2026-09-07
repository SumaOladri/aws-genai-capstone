# AWS GenAI Capstone — Serverless Recipe Generator

A serverless web application on AWS. An authenticated user submits a list of ingredients and receives a generated recipe. Built with Python, FastAPI, and Terraform.

---

## Table of contents

- [Architecture](#architecture)
- [Request flow](#request-flow)
- [Repository layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [First-time setup](#first-time-setup)
- [Terraform files explained](#terraform-files-explained)
- [Application files explained](#application-files-explained)
- [Everyday commands](#everyday-commands)
- [Deploying a code change](#deploying-a-code-change)
- [Checking logs and URLs](#checking-logs-and-urls)
- [Environment variables](#environment-variables)
- [IAM permissions](#iam-permissions)
- [Current status: Bedrock is mocked by default](#current-status-bedrock-is-mocked-by-default)
- [Enabling the real model](#enabling-the-real-model)
- [Adding a new environment](#adding-a-new-environment)
- [Teardown and rebuild](#teardown-and-rebuild)
- [Known issues and gotchas](#known-issues-and-gotchas)

---

## Architecture

```
                    Browser
                       │
                       ▼
        ┌──────────────────────────────┐
        │  API Gateway (HTTP API)      │   public URL
        │  $default route → AWS_PROXY  │
        └──────────────┬───────────────┘
                       │
                       ▼
        ┌──────────────────────────────┐
        │  Lambda (Python 3.12)        │
        │    lambda_handler.handler    │
        │      └─ Mangum               │
        │          └─ FastAPI          │
        │              ├─ Jinja2 HTML  │
        │              ├─ auth.py      │──► Cognito (hosted UI, JWKS, token exchange)
        │              └─ bedrock.py   │──► Bedrock (currently mocked)
        └──────┬───────────────┬───────┘
               │               │
               ▼               ▼
      SSM Parameter Store   CloudWatch Logs
      (client secret)       (7-day retention)
```

Everything is defined in Terraform. State lives in S3.

| Concern | Service |
|---|---|
| Public endpoint | API Gateway HTTP API |
| Compute | Lambda, Python 3.12, 512 MB, 60s timeout |
| Web framework | FastAPI + Mangum (ASGI→Lambda adapter) |
| UI | Jinja2 server-rendered HTML (no JS build step) |
| Authentication | Cognito user pool + hosted UI, OAuth authorization code flow |
| Session | Signed JWT in an httpOnly cookie, verified per request |
| Secrets | SSM Parameter Store, SecureString |
| Model | Amazon Bedrock (Claude Haiku 4.5) — **currently mocked** |
| Logging | CloudWatch Logs |
| Infrastructure as code | Terraform 1.16, S3 remote state with native locking |

---

## Request flow

**Unauthenticated visitor**

1. `GET /` → Lambda → no session cookie → renders page with a "Sign in" link.

**Sign-in**

1. `GET /login` → 302 to the Cognito hosted UI.
2. User signs up (email + password) or signs in. Cognito emails a 6-digit verification code on first sign-up.
3. Cognito redirects to `GET /callback?code=…`.
4. `/callback` reads the client secret from SSM, POSTs to Cognito's `/oauth2/token` with HTTP Basic auth, and receives an ID token and access token.
5. Both tokens are set as `httponly`, `secure`, `samesite=lax` cookies. 302 to `/`.

**Authenticated request**

1. `POST /generate` → `current_user()` reads both cookies.
2. `auth.verify_token()` fetches Cognito's JWKS (cached), then validates the ID token's signature, issuer, audience, and `at_hash`.
3. Valid → ingredients are split on commas and passed to `generate_recipe()`.
4. Invalid or absent → 302 to `/login`.

**Why validation happens in FastAPI rather than an API Gateway JWT authorizer:** the authorizer rejects unauthenticated requests with a 401 JSON body before Lambda is invoked, so there is no opportunity to redirect. For a browser-facing HTML app, a redirect to the login page is the correct behaviour. The authorizer would be the right choice for a JSON API consumed by a SPA or mobile client.

---

## Repository layout

```
aws-recipe-capstone/
├── app/
│   ├── __init__.py
│   ├── main.py                  FastAPI routes and session handling
│   ├── auth.py                  Cognito URLs, token exchange, JWT verification
│   ├── bedrock.py               Model invocation + mock implementation
│   └── templates/
│       └── index.html           Single Jinja2 template
├── infra/
│   ├── versions.tf              Terraform + provider version constraints
│   ├── backend.tf               Declares S3 backend (values supplied at init)
│   ├── provider.tf              AWS provider config + default tags
│   ├── variables.tf             Input variable declarations (no defaults)
│   ├── locals.tf                Computed name_prefix and base_url
│   ├── iam.tf                   Lambda execution role and policies
│   ├── lambda.tf                Function, log group, zip packaging
│   ├── apigateway.tf            HTTP API, route, integration, stage, permission
│   ├── cognito.tf               User pool, domain, app client, SSM parameter
│   ├── outputs.tf               Values printed after apply
│   └── env/
│       ├── dev.backend.hcl      Where dev state lives (used at init)
│       └── dev.tfvars           Dev variable values (used at plan/apply)
├── lambda_handler.py            Mangum entry point
├── build.sh                     Assembles the Lambda deployment package
├── pyproject.toml               Dependencies (managed by uv)
├── uv.lock                      Pinned dependency versions
└── README.md
```

Generated, not in git: `build/`, `infra/.terraform/`, `infra/.artifacts/`, `.venv/`.

---

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| AWS CLI | v2 | `curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip && unzip awscliv2.zip && sudo ./aws/install` |
| Terraform | ≥ 1.10 | HashiCorp apt repo (1.10+ required for S3 native state locking) |
| uv | latest | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |
| Python | 3.12 | Managed by uv |

An AWS account with administrator access, and an S3 bucket for Terraform state.

---

## First-time setup

### 1. AWS credentials (IAM Identity Center)

This project uses IAM Identity Center rather than long-lived access keys. Credentials expire on their own, so a leak has a bounded blast radius, and there is no permanent secret in `~/.aws/credentials`.

```bash
aws configure sso
```

| Prompt | Value |
|---|---|
| SSO session name | `<your-profile>` |
| SSO start URL | `https://d-xxxxxxxxxx.awsapps.com/start` |
| SSO region | `ap-south-1` (where Identity Center lives) |
| SSO registration scopes | *(press Enter — accepts `sso:account:access`)* |
| CLI default client Region | `us-east-1` (where resources are created) |
| CLI default output format | `json` |
| CLI profile name | `<your-profile>` |

The two regions are deliberately different: Identity Center is in ap-south-1, resources are in us-east-1.

```bash
export AWS_PROFILE=<your-profile>
echo 'export AWS_PROFILE=<your-profile>' >> ~/.bashrc
aws sts get-caller-identity
```

Sessions last 8 hours. When commands start failing with token errors:

```bash
aws sso login --profile <your-profile>
```

### 2. State bucket

Terraform stores state in S3, but cannot create the bucket it needs to store state in. This is a one-time bootstrap done outside Terraform.

```bash
aws s3api create-bucket \
  --bucket <your-tf-state-bucket> \
  --region us-east-1

# Recommended: versioning protects against state corruption
aws s3api put-bucket-versioning \
  --bucket <your-tf-state-bucket> \
  --versioning-configuration Status=Enabled
```

### 3. Python environment

```bash
uv sync
```

### 4. Initialise Terraform

```bash
cd infra
terraform init -backend-config=env/dev.backend.hcl
```

### 5. Build and deploy

```bash
cd ..
./build.sh
cd infra
terraform apply -var-file=env/dev.tfvars
```

---

## Terraform files explained

### `versions.tf`

Pins Terraform and provider versions. Creates nothing.

- `required_version = ">= 1.10"` — S3 native state locking (`use_lockfile`) requires 1.10+. Older guides use a DynamoDB table for this; that is no longer necessary.
- `hashicorp/aws ~> 5.0` — any 5.x, never 6.0. Major provider versions can rename or remove resources.
- `hashicorp/archive ~> 2.4` — zips the build directory. Not an AWS operation, hence a separate provider.

### `backend.tf`

Declares that state lives in S3, with **no values**:

```hcl
terraform {
  backend "s3" {}
}
```

This is *partial backend configuration*. Backend blocks cannot use variables, because Terraform reads them before variables are evaluated. Supplying values at init time instead is what allows one set of `.tf` files to serve multiple environments:

```bash
terraform init -backend-config=env/dev.backend.hcl
terraform init -backend-config=env/uat.backend.hcl   # later
```

### `env/dev.backend.hcl`

```hcl
bucket       = "<your-tf-state-bucket>"
key          = "genai-capstone/dev/terraform.tfstate"
region       = "us-east-1"
profile      = "<your-profile>"
use_lockfile = true
```

`use_lockfile = true` writes a lock object to S3 during apply so two concurrent runs cannot interleave writes and corrupt state.

### `provider.tf`

Configures the AWS provider. Unlike the backend block, this *can* use variables — providers are configured after variables are evaluated.

`default_tags` applies `Project`, `Environment`, and `ManagedBy` to every taggable resource automatically. This gives cost attribution in Cost Explorer, makes cleanup findable, and signals to anyone in the console that a resource should not be edited by hand.

### `variables.tf`

Declares the stack's inputs, in two groups.

The four placement variables — `project`, `environment`, `region`, `aws_profile` — have **no defaults**. A variable without a default is required, so `terraform apply` fails unless a `-var-file` is passed. This makes it impossible to accidentally deploy to the wrong environment by omitting a flag.

The two model variables — `use_mock` and `model_id` — do have defaults, because there is a sane answer for both and neither one risks deploying to the wrong place. `use_mock` defaults to `true` so a fresh clone comes up working without Bedrock access.

### `locals.tf`

```hcl
locals {
  name_prefix = "${var.project}-${var.environment}"
  base_url    = trimsuffix(aws_apigatewayv2_stage.default.invoke_url, "/")
}
```

- `name_prefix` → `genai-capstone-dev`. Every resource name derives from it, so dev and uat resources never collide.
- `base_url` → the API Gateway URL with any trailing slash removed. `invoke_url` ends with `/`, so appending `/callback` directly produces `…amazonaws.com//callback` — a double slash that causes a Cognito `redirect_mismatch` error.

### `iam.tf`

Creates the Lambda execution role and attaches two policies.

**Trust policy** (`data.aws_iam_policy_document.lambda_assume_role`) — states that `lambda.amazonaws.com` may assume the role. This is stamped onto the role itself; it is not a separate object. Without it, Lambda refuses to create the function.

**`AWSLambdaBasicExecutionRole`** — AWS-managed, attached by ARN. Grants `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`. Without it the function runs but produces no logs.

**`genai-capstone-dev-lambda-ssm`** — written here, in three blocks (document → policy → attachment) because the policy does not already exist in AWS. Grants `ssm:GetParameter` and `ssm:GetParameters` on **one specific parameter ARN**, not `ssm:*`.

> **Trust policy vs permissions policy.** The trust policy answers *who may assume this role*. Permissions policies answer *what the role can do once assumed*. Both are required and they are not interchangeable.

### `lambda.tf`

**`data.archive_file.lambda`** — zips `../build` into `.artifacts/lambda.zip`.

**`aws_cloudwatch_log_group.lambda`** — declared explicitly rather than letting Lambda auto-create it. The auto-created group has **no expiry**, so logs accumulate and bill forever, and it survives `terraform destroy`. Declaring it gives 7-day retention and clean teardown.

**`aws_lambda_function.api`**
- `handler = "lambda_handler.handler"` — the `handler` object in `lambda_handler.py`.
- `source_code_hash` — hashes the zip contents. Without it Terraform compares filenames, sees no change, and silently skips deploying new code. See [Known issues](#known-issues-and-gotchas) — this still needs `-replace` in practice.
- `timeout = 60` — the Lambda default is 3 seconds, which is too short for Bedrock calls.
- `depends_on` the log group — the log group is not referenced by the function, so the ordering must be stated explicitly. Otherwise Lambda may auto-create the group first and Terraform then fails.

### `apigateway.tf`

**`aws_apigatewayv2_api`** — HTTP API, chosen over REST API: ~70% cheaper, lower latency, and it has a native Cognito JWT authorizer available if ever needed.

**`aws_apigatewayv2_integration`** — `AWS_PROXY` passes the entire HTTP request to Lambda untransformed. The alternative (mapping templates) would duplicate work Mangum already does.

**`aws_apigatewayv2_route`** — `route_key = "$default"` is a catch-all. FastAPI does the routing; API Gateway should not duplicate it.

**`aws_apigatewayv2_stage`** — the `$default` stage with `auto_deploy = true`. REST APIs require an explicit deploy step after every change; this avoids that, and `$default` keeps the stage name out of the URL.

**`access_log_settings`** — logs every request with status and latency to a separate log group. This is where to look when a request fails *before* reaching your code.

**`aws_lambda_permission`** — a **resource policy** on the function allowing `apigateway.amazonaws.com` to invoke it. Without this, API Gateway gets 403 and returns a 500 to the browser with **nothing in the Lambda logs**. The console creates this silently when you attach an integration through the UI, which is why its absence surprises people in Terraform. `source_arn` scopes it to this API only.

### `cognito.tf`

**`aws_cognito_user_pool`** — the user directory.
- `username_attributes = ["email"]` — sign in with email, no separate username.
- `auto_verified_attributes = ["email"]` — Cognito emails a verification code on sign-up.
- `password_policy` — 8+ chars, upper, lower, number. These rules are rendered live on the hosted sign-up page.

**`aws_cognito_user_pool_domain`** — hosts the login pages. The domain prefix includes the account ID because Cognito domain prefixes are globally unique across all AWS customers, the same constraint as S3 bucket names.

**`aws_cognito_user_pool_client`**
- `generate_secret = true` — a **confidential client**. Safe only because the secret stays server-side in Lambda. A browser-based SPA must use `false`, since it cannot hide anything.
- `allowed_oauth_flows = ["code"]` — authorization code flow. Cognito returns a short-lived code; the server exchanges it for tokens over a back channel. The alternative (implicit flow) puts tokens directly in the URL where they leak into browser history and server logs.
- `callback_urls` — must match the redirect URI byte for byte, including trailing slashes.
- Tokens: 1 hour for access and ID, 30 days for refresh.

**`aws_ssm_parameter.cognito_client_secret`** — stores the generated client secret as a `SecureString`, encrypted with the AWS-managed `aws/ssm` KMS key.

> **Why not a plain environment variable?** It would sit in the Lambda configuration in cleartext, visible to anyone with console read access, and would appear in `terraform plan` output — including CI logs. With SSM, `plan` shows `(sensitive value)`.
>
> The secret **is** still written to the Terraform state file in cleartext. That is unavoidable — Terraform must track what it created. It is the reason state belongs in a private S3 bucket and never in git.

### `outputs.tf`

Values printed after apply and stored in state. Retrieve individually with `terraform output -raw <name>`.

---

## Application files explained

### `lambda_handler.py`

```python
from mangum import Mangum
from app.main import app

handler = Mangum(app, lifespan="off")
```

Lambda passes a JSON event dict; FastAPI speaks ASGI. Mangum translates between them. `lifespan="off"` because FastAPI's startup/shutdown hooks assume a long-running server and can hang a Lambda invocation.

Your application code is completely unaware it is running on Lambda — the same `app` object runs locally under uvicorn.

### `app/auth.py`

- `client_secret()` — reads the secret from SSM. `@lru_cache` means once per warm container, not once per request.
- `jwks()` — fetches Cognito's public signing keys. Also cached.
- `login_url()` / `logout_url()` — build hosted UI redirect URLs.
- `exchange_code()` — POSTs the auth code to Cognito's token endpoint using HTTP Basic auth (`client_id` : `client_secret`). This is what `generate_secret = true` exists for.
- `verify_token()` — validates signature against the JWKS key, plus issuer, audience, and `at_hash`. Returns `None` on failure rather than raising, so callers can simply redirect.

> **`at_hash` requires the access token.** Cognito ID tokens carry an `at_hash` claim binding them to the matching access token. `python-jose` sees the claim and insists on verifying it. Passing only the ID token produces:
> ```
> JWTClaimsError: No access_token provided to compare against at_hash claim.
> ```
> This is why both tokens are stored as cookies and both are passed to `verify_token()`.

### `app/main.py`

| Route | Auth | Purpose |
|---|---|---|
| `GET /health` | public | Liveness check |
| `GET /` | public | Renders the form; shows sign-in state |
| `GET /login` | public | 302 to Cognito hosted UI |
| `GET /callback` | public | Exchanges code for tokens, sets cookies |
| `GET /logout` | public | Clears cookies, 302 to Cognito logout |
| `POST /generate` | **required** | Generates a recipe |

Cookie flags: `httponly=True` blocks JavaScript access (the main XSS token-theft path), `secure=True` restricts to HTTPS, `samesite="lax"` mitigates CSRF while still permitting the Cognito redirect.

Session state lives entirely in the signed cookie. Lambda has no shared session store, and the token is verified against Cognito's public key on every request, so a tampered cookie fails verification.

`/` is public and `/generate` is protected — visitors see a login prompt rather than a redirect loop, and only signed-in users can spend the Bedrock budget.

### `app/bedrock.py`

`generate_recipe(ingredients)` returns either a mock recipe or a real model response, depending on `USE_MOCK`. The boto3 client is constructed **inside** the function so mock mode needs no AWS credentials at all — the module imports and runs on a machine with no AWS profile configured.

### `build.sh`

**Lambda does not install dependencies.** It unzips the package into `/var/task`, adds it to `sys.path`, and imports the handler. There is no pip, no build step, no `requirements.txt` processing at runtime — that would make cold starts unacceptably slow. Everything the code imports must physically be in the zip.

What the script does:

1. Delete `build/` — stale files from a previous build would otherwise ship.
2. `uv export` the locked dependencies to a requirements file.
3. `uv pip install --target build` — installs flat into a directory rather than a venv, which is the layout Lambda expects.
4. Copy `app/` and `lambda_handler.py`.
5. Delete bundled `boto3`/`botocore`/`s3transfer` — the Lambda runtime provides these; a duplicate adds ~50 MB for nothing.
6. Delete `__pycache__`.

Critical flags:

| Flag | Why |
|---|---|
| `--python-platform x86_64-manylinux2014` | Installs Linux wheels regardless of the build machine. Lambda runs Amazon Linux 2023; packages with C extensions (e.g. `cryptography`) built for another platform fail at import. |
| `--python-version 3.12` | Matches the Lambda runtime. |
| `--only-binary=:all:` | Fail loudly if no compatible wheel exists, rather than building from source and producing something that breaks on Lambda. |

SAM's `sam build` does all of this in one command. Terraform does not build artifacts, so this script is the missing half.

---

## Everyday commands

All Terraform commands run from `infra/`.

```bash
# Refresh expired credentials (every 8 hours)
aws sso login --profile <your-profile>

# Preview changes — creates nothing
terraform plan -var-file=env/dev.tfvars

# Apply changes
terraform apply -var-file=env/dev.tfvars

# Format and validate
terraform fmt -recursive
terraform validate

# Show all outputs
terraform output

# Show one output, unquoted
terraform output -raw api_url

# Inspect state
terraform state list
terraform state show aws_lambda_function.api
```

From the project root:

```bash
# Rebuild the deployment package
./build.sh

# Run locally (mock mode, no AWS needed)
USE_MOCK=true uv run uvicorn app.main:app --reload
# → http://127.0.0.1:8000

# Syntax check before deploying
uv run python -c "import ast; ast.parse(open('app/main.py').read()); ast.parse(open('app/auth.py').read()); print('ok')"
```

---

## Deploying a code change

```bash
# 1. Rebuild the package
cd ~/path/to/aws-recipe-capstone
./build.sh

# 2. Verify the change is actually in the build
grep -c "your_new_function" build/app/main.py

# 3. Deploy — note the two -replace flags
cd infra
terraform apply -var-file=env/dev.tfvars \
  -replace=aws_lambda_function.api \
  -replace=aws_lambda_permission.api_gateway

# 4. Confirm the deploy timestamp moved
aws lambda get-function-configuration \
  --function-name genai-capstone-dev-api \
  --query 'LastModified' --output text
```

**Why `-replace` is needed.** `archive_file` recomputes the zip hash, but Terraform evaluates `source_code_hash` before the zip is rewritten, so it compares stale values and reports "No changes" even when `build/` has changed. This is a well-known rough edge of Terraform for Lambda and one of the concrete reasons SAM exists.

**Why the second `-replace`.** `aws_lambda_permission` is a resource policy attached *to the function*. Recreating the function silently discards it, but Terraform still believes it exists. The symptom is a 500 from API Gateway with **zero entries in the Lambda logs** — because Lambda was never invoked.

---

## Checking logs and URLs

### URLs

```bash
cd infra

terraform output -raw api_url
terraform output -raw cognito_domain
terraform output -raw cognito_client_id
terraform output -raw cognito_user_pool_id
```

Construct the hosted UI login URL manually:

```bash
echo "$(terraform output -raw cognito_domain)/login\
?client_id=$(terraform output -raw cognito_client_id)\
&response_type=code\
&scope=email+openid+profile\
&redirect_uri=$(terraform output -raw api_url | sed 's:/*$::')/callback"
```

### Logs

```bash
# Application logs — Python tracebacks and logger output
aws logs tail /aws/lambda/genai-capstone-dev-api --since 15m

# Follow live while reproducing a problem
aws logs tail /aws/lambda/genai-capstone-dev-api --since 1m --follow

# Errors only
aws logs tail /aws/lambda/genai-capstone-dev-api --since 1h --filter-pattern "ERROR"

# API Gateway access logs — status and latency per request.
# Look here when a request fails BEFORE reaching your code.
aws logs tail /aws/apigateway/genai-capstone-dev --since 15m
```

> **Empty Lambda logs during a 500 means Lambda was never invoked.** The failure is upstream — almost always a missing `aws_lambda_permission`.

### Health and smoke tests

```bash
# End to end through API Gateway
curl $(terraform output -raw api_url)health

# Bypass API Gateway — invoke the function directly with a synthetic
# API Gateway v2 event. Isolates the function from the gateway.
aws lambda invoke \
  --function-name genai-capstone-dev-api \
  --payload '{"version":"2.0","rawPath":"/health","rawQueryString":"","headers":{"host":"localhost"},"requestContext":{"http":{"method":"GET","path":"/health","protocol":"HTTP/1.1","sourceIp":"127.0.0.1","userAgent":"cli"},"requestId":"test","stage":"$default"},"isBase64Encoded":false}' \
  --cli-binary-format raw-in-base64-out \
  /dev/stdout
```

Mangum requires `requestContext.http.sourceIp`; omitting it raises `KeyError: 'sourceIp'`.

### Inspecting resources

```bash
# Lambda config and env vars
aws lambda get-function-configuration --function-name genai-capstone-dev-api

# Resource policy — who may invoke the function
aws lambda get-policy --function-name genai-capstone-dev-api \
  --query 'Policy' --output text | python3 -m json.tool

# Role policies — what the function may do
aws iam list-attached-role-policies --role-name genai-capstone-dev-lambda-role

# Cognito app client — callback URLs, flows, scopes
aws cognito-idp describe-user-pool-client \
  --user-pool-id $(cd infra && terraform output -raw cognito_user_pool_id) \
  --client-id $(cd infra && terraform output -raw cognito_client_id)

# Confirm the parameter is encrypted (queries type only, not the value)
aws ssm get-parameter \
  --name /genai-capstone-dev/cognito/client-secret \
  --with-decryption --query 'Parameter.Type' --output text
```

### Decoding a session token

In the browser: **F12 → Storage → Cookies →** the API Gateway domain. Paste the `id_token` value into https://jwt.io to inspect the claims — `email`, `aud` (should equal the client ID), `iss` (should equal the user pool issuer), and `at_hash`.

---

## Environment variables

Set on the Lambda by Terraform. Nothing here is secret — `COGNITO_SECRET_PARAM` holds a *path*, and the value is fetched from SSM at runtime.

| Variable | Example | Purpose |
|---|---|---|
| `USE_MOCK` | `true` | Return a canned recipe instead of calling Bedrock. Set by the `use_mock` Terraform variable |
| `MODEL_ID` | `us.anthropic.claude-haiku-4-5-20251001-v1:0` | Bedrock inference profile ID. Set by the `model_id` Terraform variable |
| `COGNITO_DOMAIN` | `https://genai-capstone-dev-….auth.us-east-1.amazoncognito.com` | Hosted UI base URL |
| `COGNITO_CLIENT_ID` | `<client-id>` | App client ID; also the expected JWT audience |
| `COGNITO_USER_POOL_ID` | `us-east-1_…` | Used to build the JWT issuer URL |
| `COGNITO_SECRET_PARAM` | `/genai-capstone-dev/cognito/client-secret` | SSM path, not the secret itself |
| `APP_BASE_URL` | `https://….execute-api.us-east-1.amazonaws.com` | Used to build the redirect URI |
| `AWS_REGION_NAME` | `us-east-1` | Not `AWS_REGION` — Lambda reserves that name and rejects it |

---

## IAM permissions

### Execution role — what the function can do

`genai-capstone-dev-lambda-role`, with three attached policies:

**`AWSLambdaBasicExecutionRole`** (AWS-managed)
```json
{
  "Effect": "Allow",
  "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
  "Resource": "arn:aws:logs:*:*:*"
}
```

**`genai-capstone-dev-lambda-ssm`** (defined in this repo)
```json
{
  "Effect": "Allow",
  "Action": ["ssm:GetParameter", "ssm:GetParameters"],
  "Resource": "arn:aws:ssm:us-east-1:<account>:parameter/genai-capstone-dev/cognito/client-secret"
}
```

Scoped to a single parameter ARN. No `PutParameter`, no `DeleteParameter`, no wildcards. If the function were compromised, that is the blast radius.

No `kms:Decrypt` is needed because the parameter uses the AWS-managed `aws/ssm` key, whose own key policy permits decryption by principals already authorised to call SSM. A customer-managed key **would** require an explicit `kms:Decrypt` grant.

**`genai-capstone-dev-lambda-bedrock`** (defined in this repo)
```json
{
  "Effect": "Allow",
  "Action": ["bedrock:InvokeModel"],
  "Resource": [
    "arn:aws:bedrock:us-east-1:<account>:inference-profile/us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "arn:aws:bedrock:*::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0"
  ]
}
```

Attached unconditionally, regardless of `use_mock`, so enabling the real model is a variable change rather than an IAM change. Both ARNs are required — see [Enabling the real model](#enabling-the-real-model) for why. The foundation-model ARN has a `*` region because a `us.` inference profile may route to any US region, and an empty account segment because foundation models are not account-scoped.

### Resource policy — who can invoke the function

```json
{
  "Sid": "AllowInvokeFromApiGateway",
  "Effect": "Allow",
  "Principal": { "Service": "apigateway.amazonaws.com" },
  "Action": "lambda:InvokeFunction",
  "Condition": {
    "ArnLike": { "AWS:SourceArn": "arn:aws:execute-api:us-east-1:<account>:<api-id>/*/*" }
  }
}
```

Opposite direction from the execution role, and scoped to this specific API rather than any API Gateway in the account.

---

## Current status: Bedrock is mocked by default

`use_mock = true` in `env/dev.tfvars`, so `generate_recipe()` returns a formatted template built from the submitted ingredients, clearly marked as a mock in the output.

**Why:** the AWS account was under new-account verification, which blocks Bedrock `InvokeModel` (and CloudShell) entirely. Verification takes up to two days for new accounts.

The IAM grant is already in the stack — turning the real model on is a one-variable change, not a code change. See [Enabling the real model](#enabling-the-real-model).

Diagnosis notes, in case this recurs:

| Symptom | Meaning |
|---|---|
| `AccessDeniedException: Your account is currently being verified` | Account-level hold; wait |
| `ValidationException: Operation not allowed` on **every** model including Amazon Nova | Still an account-level hold — Nova has no third-party agreement, so a failure there rules out anything Anthropic-specific |
| `ValidationException: … on-demand throughput isn't supported` | Using a bare model ID where an inference profile (`us.` prefix) is required |
| `agreementAvailability: NOT_AVAILABLE` | Provider EULA not accepted for this model |

Check current state:

```bash
aws bedrock get-foundation-model-availability \
  --region us-east-1 \
  --model-id anthropic.claude-haiku-4-5-20251001-v1:0
```

Four fields to read: `regionAvailability` (model exists here), `entitlementAvailability` (account may have it), `agreementAvailability` (EULA accepted), `authorizationStatus` (net result).

---

## Enabling the real model

Once `InvokeModel` succeeds from the CLI:

### 1. Confirm access

```bash
aws bedrock-runtime invoke-model \
  --region us-east-1 \
  --model-id us.anthropic.claude-haiku-4-5-20251001-v1:0 \
  --body '{"anthropic_version":"bedrock-2023-05-31","max_tokens":50,"messages":[{"role":"user","content":"hi"}]}' \
  --cli-binary-format raw-in-base64-out \
  /dev/stdout
```

### 2. Flip the flag

The IAM policy is already applied — `infra/iam.tf` grants `bedrock:InvokeModel` on both the inference profile and the foundation model behind it, whether or not `use_mock` is set, so switching modes never needs an IAM edit.

> **Both ARN types are required, and that is why the policy looks the way it does.** A `us.`-prefixed profile is a *cross-region inference profile*: it routes requests to whichever of several regions has capacity. Granting only the profile ARN produces an `AccessDeniedException` naming a region you never explicitly configured — the single most common Bedrock IAM mistake. `local.foundation_model_id` strips the `us.` prefix to derive the model ID, and the model ARN uses a `*` region because a foundation model is not account-scoped.

In `infra/env/dev.tfvars`:

```hcl
use_mock = true   # → false
```

To try a different model, set `model_id` alongside it — the IAM policy follows the variable, so no other file changes:

```hcl
model_id = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
```

### 3. Deploy

```bash
cd infra
terraform apply -var-file=env/dev.tfvars
```

No rebuild needed — only the environment variable and the IAM policy change.

Confirm the flag actually moved:

```bash
aws lambda get-function-configuration \
  --function-name genai-capstone-dev-api \
  --region us-east-1 \
  --query 'Environment.Variables.{USE_MOCK:USE_MOCK,MODEL_ID:MODEL_ID}'
```

---

## Adding a new environment

Two new files. No changes to any `.tf` file.

**`infra/env/uat.backend.hcl`**
```hcl
bucket       = "<your-tf-state-bucket>"
key          = "genai-capstone/uat/terraform.tfstate"
region       = "us-east-1"
profile      = "<your-profile>"
use_lockfile = true
```

**`infra/env/uat.tfvars`**
```hcl
project     = "genai-capstone"
environment = "uat"
region      = "us-east-1"
aws_profile = "<your-profile>"
```

```bash
terraform init -reconfigure -backend-config=env/uat.backend.hcl
terraform apply -var-file=env/uat.tfvars
```

Every resource name is derived from `local.name_prefix`, so uat resources are named `genai-capstone-uat-*` and cannot collide with dev.

> **Why separate state files rather than workspaces?** HashiCorp's guidance is that workspaces suit short-lived parallel copies of identical infrastructure, not long-lived environments. With workspaces, one backend holds all environments (so a credential reaching dev can reach prod), a forgotten `terraform workspace select` silently targets the wrong environment, and divergence between environments has no clean expression. Separate backend configs make the target explicit on every command.

`-reconfigure` is required when switching backends, since Terraform would otherwise try to migrate state.

---

## Teardown and rebuild

The whole point of keeping this in Terraform: the stack can be deleted when it
is not being used and rebuilt on demand. Idle cost is near zero — Lambda and
API Gateway bill per request — so this is more about tidiness than money, but
the cycle is worth knowing.

### Destroy

```bash
aws sso login --profile SUMA          # token expires every 8 hours
cd infra
terraform destroy -var-file=env/dev.tfvars
```

Takes about two minutes. Destroys everything: Lambda, API Gateway, Cognito pool
(**and all registered users**), IAM role and policies, SSM parameter, both log
groups.

### Rebuild

Four commands from a clean clone:

```bash
git clone git@github.com:SumaOladri/aws-genai-capstone.git
cd aws-genai-capstone

aws sso login --profile SUMA
./build.sh                                            # build/ is gitignored
cd infra
terraform init -backend-config=env/dev.backend.hcl    # skip if .terraform/ exists
terraform apply -var-file=env/dev.tfvars
```

Then read the new URL off the outputs:

```bash
terraform output -raw api_url
```

`./build.sh` is not optional. `build/` is gitignored — it is 32 MB of installed
dependencies — and `data.archive_file.lambda` zips that directory, so a fresh
clone has nothing to package and `apply` fails at the archive step.

There is no ordering trap beyond that. Terraform resolves the rest itself: the
API Gateway stage is created first, its `invoke_url` becomes `local.base_url`,
that fills the Cognito client's `callback_urls`, and the client ID and secret
land in the Lambda's environment. One apply, no second pass, no manual console
step, no imports.

### What does not survive a rebuild

| Changes | Consequence |
|---|---|
| API Gateway URL | The whole hostname is new; update any bookmark |
| Cognito pool ID and client ID | Every registered user account is gone with the old pool |
| Cognito hosted UI hostname | Includes the account ID, so it is stable — but the pool behind it is not |
| Client secret | Regenerated and rewritten to SSM automatically |

Nothing needs to be copied by hand: the callback URL is derived from the new API
Gateway URL on the same apply, which is the reason it is `local.base_url` rather
than a hardcoded string.

### Not destroyed — created outside Terraform

```bash
# The state bucket
aws s3 rm s3://<your-tf-state-bucket> --recursive
aws s3api delete-bucket --bucket <your-tf-state-bucket> --region us-east-1
```

### Verify nothing survived

```bash
aws lambda list-functions --region us-east-1 \
  --query 'Functions[?starts_with(FunctionName, `genai-capstone`)].FunctionName'
aws apigatewayv2 get-apis --region us-east-1 \
  --query 'Items[?starts_with(Name, `genai-capstone`)].Name'
aws cognito-idp list-user-pools --max-results 20 --region us-east-1 \
  --query 'UserPools[?starts_with(Name, `genai-capstone`)].Name'
aws logs describe-log-groups --region us-east-1 \
  --log-group-name-prefix "/aws/lambda/genai-capstone"
```

---

## Known issues and gotchas

Every item below was hit during development.

### Terraform reports "No changes" after a code change

`archive_file` computes a new hash, but `source_code_hash` is evaluated against the previous zip. Use `-replace=aws_lambda_function.api`.

### 500 from API Gateway with empty Lambda logs

`aws_lambda_permission` was destroyed along with the function during a `-replace`, but remains in state. Always pass both replace flags together:

```bash
-replace=aws_lambda_function.api -replace=aws_lambda_permission.api_gateway
```

### Cognito `redirect_mismatch`

`invoke_url` ends with `/`. Appending `/callback` produces a double slash. Cognito requires byte-exact matching. Fixed by `trimsuffix()` in `locals.tf`. Diagnose with:

```bash
aws cognito-idp describe-user-pool-client \
  --user-pool-id <id> --client-id <id> \
  --query 'UserPoolClient.CallbackURLs'
```

### `JWTClaimsError: No access_token provided to compare against at_hash claim`

Cognito ID tokens carry `at_hash`. `python-jose` insists on verifying it. Store both tokens as cookies and pass the access token to `verify_token()`. (Disabling the check with `options={"verify_at_hash": False}` also works but weakens validation.)

### `KeyError: 'sourceIp'` when hand-invoking the function

Mangum requires `requestContext.http.sourceIp`. Real API Gateway events always include it; hand-written test payloads often do not.

### `TypeError: unhashable type: 'dict'` from Jinja2Templates

Starlette 1.x is incompatible with the `Jinja2Templates` API that FastAPI 0.141 expects. Pin Starlette to the 0.4x line. The lockfile now holds a working combination — do not upgrade blindly.

### `uv add` fails: "Expected a Python module at src/…"

`uv init` scaffolds an installable package. This project is an application, not a library. Add to `pyproject.toml`:

```toml
[tool.uv]
package = false
```

### SSO token expired

Permission set sessions last 8 hours.

```bash
aws sso login --profile <your-profile>
```
