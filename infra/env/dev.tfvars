project     = "genai-capstone"
environment = "dev"
region      = "us-east-1"
aws_profile = "SUMA"
# Bedrock was returning ValidationException under the account verification
# hold, so the model stays mocked until access is confirmed. Flip to false
# and re-apply — the IAM grant is already in place.
use_mock = true
