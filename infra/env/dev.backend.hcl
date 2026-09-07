# The state bucket is a one-time bootstrap outside Terraform, and its name is
# account-specific — supply it at init time rather than committing it:
#
#   terraform init -backend-config=env/dev.backend.hcl \
#     -backend-config="bucket=<your-tf-state-bucket>"
#
# Or copy this file to env/dev.backend.local.hcl (gitignored) with the bucket
# line filled in.
key          = "genai-capstone/dev/terraform.tfstate"
region       = "us-east-1"
profile      = "SUMA"
use_lockfile = true
