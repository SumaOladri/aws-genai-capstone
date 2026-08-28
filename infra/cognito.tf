# The user directory: holds accounts, passwords, email verification.
resource "aws_cognito_user_pool" "main" {
  name = "${local.name_prefix}-users"

  # Users sign in with their email address rather than a username.
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = false
  }

  # Cognito emails a code; the user enters it to confirm their account.
  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
    email_subject        = "Welcome to Recipe AI"
    email_message        = "Your verification code is {####}"
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
}

# Hosted UI lives at https://<domain>.auth.<region>.amazoncognito.com
resource "aws_cognito_user_pool_domain" "main" {
  domain       = "${local.name_prefix}-${data.aws_caller_identity.current.account_id}"
  user_pool_id = aws_cognito_user_pool.main.id
}

data "aws_caller_identity" "current" {}

# Your application's registration with the pool.
resource "aws_cognito_user_pool_client" "web" {
  name         = "${local.name_prefix}-web-client"
  user_pool_id = aws_cognito_user_pool.main.id

  # A confidential client: the secret stays server-side in Lambda.
  generate_secret = true

  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["email", "openid", "profile"]

  supported_identity_providers = ["COGNITO"]

  callback_urls = ["${local.base_url}/callback"]
  logout_urls   = ["${local.base_url}/"]

  # Tokens the app receives after login.
  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 30

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }
}

# Client secret stored encrypted rather than passed as a plain env var.
resource "aws_ssm_parameter" "cognito_client_secret" {
  name        = "/${local.name_prefix}/cognito/client-secret"
  description = "Cognito app client secret for ${local.name_prefix}"
  type        = "SecureString"
  value       = aws_cognito_user_pool_client.web.client_secret
}