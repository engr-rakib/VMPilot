/*
Example S3 backend configuration. Do not commit real bucket names or credentials.
Copy or reference this file from your Terraform root and provide values via
variables or environment variables.
*/

terraform {
  backend "s3" {
    bucket         = var.tfstate_bucket     # e.g. "my-terraform-state-bucket"
    key            = var.tfstate_key        # e.g. "vmpilot/terraform.tfstate"
    region         = var.aws_region         # e.g. "us-east-1"
    dynamodb_table = var.tfstate_lock_table # e.g. "terraform-state-locks"
    encrypt        = true
  }
}
