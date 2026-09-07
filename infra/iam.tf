# Trust policy: which AWS service may assume this role.
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${local.name_prefix}-lambda-role"
  description        = "Execution role for the ${local.name_prefix} recipe API"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

# Grants permission to create log groups/streams and write log events.
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Allows the function to read its own configuration secrets.
data "aws_iam_policy_document" "lambda_ssm" {
  statement {
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]
    resources = [aws_ssm_parameter.cognito_client_secret.arn]
  }
}

resource "aws_iam_policy" "lambda_ssm" {
  name        = "${local.name_prefix}-lambda-ssm"
  description = "Read Cognito client secret from Parameter Store"
  policy      = data.aws_iam_policy_document.lambda_ssm.json
}

resource "aws_iam_role_policy_attachment" "lambda_ssm" {
  role       = aws_iam_role.lambda.name
  policy_arn = aws_iam_policy.lambda_ssm.arn
}

# Allows the function to invoke the model. Attached whether or not use_mock is
# set, so switching the flag is a one-variable change rather than an IAM edit.
data "aws_iam_policy_document" "lambda_bedrock" {
  statement {
    effect  = "Allow"
    actions = ["bedrock:InvokeModel"]

    resources = [
      # The inference profile, which lives in this account and region.
      "arn:aws:bedrock:${var.region}:${data.aws_caller_identity.current.account_id}:inference-profile/${var.model_id}",
      # The foundation model behind it. A cross-region profile may route the
      # call to any US region, and the region segment is empty because
      # foundation models are not account-scoped.
      "arn:aws:bedrock:*::foundation-model/${local.foundation_model_id}",
    ]
  }
}

resource "aws_iam_policy" "lambda_bedrock" {
  name        = "${local.name_prefix}-lambda-bedrock"
  description = "Invoke ${var.model_id} for recipe generation"
  policy      = data.aws_iam_policy_document.lambda_bedrock.json
}

resource "aws_iam_role_policy_attachment" "lambda_bedrock" {
  role       = aws_iam_role.lambda.name
  policy_arn = aws_iam_policy.lambda_bedrock.arn
}
