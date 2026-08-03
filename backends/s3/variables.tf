variable "tfstate_bucket" {
  description = "S3 bucket name to store Terraform state"
  type        = string
}

variable "tfstate_key" {
  description = "Path/key in the S3 bucket for the state file"
  type        = string
}

variable "tfstate_lock_table" {
  description = "DynamoDB table name used for state locking"
  type        = string
}

variable "aws_region" {
  description = "AWS region for S3 and DynamoDB"
  type        = string
  default     = "us-east-1"
}
