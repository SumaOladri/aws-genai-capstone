terraform {
  backend "s3" {
    # Values intentionally omitted — supplied at init time via:
    # terraform init -backend-config=env/dev.backend.hcl
  }
}