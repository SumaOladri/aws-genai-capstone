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