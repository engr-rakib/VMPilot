# S3 + DynamoDB Remote State Backend

This directory contains example configuration to use an S3 bucket for Terraform remote state with DynamoDB for state locking.

Do NOT commit secrets or actual bucket names to source control. Use the example `backend.tf` and supply values via environment variables or a secure CI secret store.

Required AWS permissions (minimum):
- `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket`
- `dynamodb:PutItem`, `dynamodb:GetItem`, `dynamodb:DeleteItem`, `dynamodb:Scan`

Usage:

1. Create an S3 bucket and a DynamoDB table for locks.
2. Copy `backend.tf` to your Terraform root (or include it) and fill in the names or use partial configuration with variables.
3. Run `terraform init` and follow prompts to migrate state if needed.


Bootstrap options:

- Use the included AWS CLI helper to create the bucket and DynamoDB table:

```bash
./backends/s3/bootstrap.sh --bucket my-terraform-state-bucket --table terraform-state-locks --region us-east-1
```

- Or deploy the included CloudFormation template:

```bash
aws cloudformation deploy --template-file backends/s3/template.yaml --stack-name terraform-backend --capabilities CAPABILITY_NAMED_IAM
```

After creating the resources, copy `backends/s3/backend.tf` into your Terraform root and run `terraform init -migrate-state` when ready.
