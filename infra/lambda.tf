# Zips the build directory into an artifact Terraform can upload.
data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../build"
  output_path = "${path.module}/.artifacts/lambda.zip"
}

# Log group created explicitly so retention is controlled and
# it is destroyed along with the rest of the stack.
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.name_prefix}-api"
  retention_in_days = 7
}

resource "aws_lambda_function" "api" {
  function_name = "${local.name_prefix}-api"
  role          = aws_iam_role.lambda.arn

  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  handler     = "lambda_handler.handler"
  runtime     = "python3.12"
  timeout     = 60
  memory_size = 512

  environment {
    variables = {
      USE_MOCK = "true"
      MODEL_ID = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_logs,
    aws_cloudwatch_log_group.lambda,
  ]
}