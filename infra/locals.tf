locals {
  name_prefix = "${var.project}-${var.environment}"
  base_url    = trimsuffix(aws_apigatewayv2_stage.default.invoke_url, "/")

  # An inference profile is a routing alias; invoking it also requires
  # permission on the foundation model behind it, whose ID is the profile ID
  # without the region prefix.
  foundation_model_id = replace(var.model_id, "/^[a-z]{2}\\./", "")
}
