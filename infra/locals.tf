locals {
  name_prefix = "${var.project}-${var.environment}"
  base_url    = trimsuffix(aws_apigatewayv2_stage.default.invoke_url, "/")
}