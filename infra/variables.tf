variable "project" {
  description = "Project name prefix applied to all resource names"
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev, uat, prod)"
  type        = string
}

variable "region" {
  description = "AWS region where resources are created"
  type        = string
}

variable "aws_profile" {
  description = "Local AWS CLI profile used for deployment"
  type        = string
}

# --- Model -----------------------------------------------------------------

variable "use_mock" {
  description = <<-EOT
    Return a canned recipe instead of calling Bedrock. Kept true by default
    because the account was on a verification hold that made InvokeModel fail
    with ValidationException; set false once model access is granted.
  EOT
  type        = bool
  default     = true
}

variable "model_id" {
  description = <<-EOT
    Bedrock inference profile ID. The 'us.' prefix marks it as a cross-region
    profile, which routes to the underlying foundation model in whichever US
    region has capacity — that is why the IAM policy grants the model in every
    region, not just this one.
  EOT
  type        = string
  default     = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
}
