#!/usr/bin/env bash
# ============================================================
# VMPilot  (c) 2026 Rakibuzzaman (Engr. Rakib)
# Original author - do not remove this attribution.
# GitHub: https://github.com/engr-rakib
# Web:    https://engr-rakib.github.io/web
# ============================================================
set -euo pipefail

# bootstrap.sh - create S3 bucket and DynamoDB table for Terraform remote state
# Usage: ./bootstrap.sh --bucket <bucket-name> --table <dynamodb-table> [--region <aws-region>]

usage() {
  echo "Usage: $0 --bucket BUCKET --table TABLE [--region REGION]"
  exit 2
}

BUCKET=""
TABLE=""
REGION="us-east-1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket) BUCKET="$2"; shift 2 ;;
    --table) TABLE="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown arg: $1"; usage ;;
  esac
done

if [ -z "$BUCKET" ] || [ -z "$TABLE" ]; then
  usage
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI not found. Install and configure AWS credentials first." >&2
  exit 1
fi

echo "Ensure S3 bucket ${BUCKET} exists (region=${REGION})"
if aws s3api head-bucket --bucket "${BUCKET}" 2>/dev/null; then
  echo "Bucket ${BUCKET} already exists"
else
  echo "Creating bucket ${BUCKET}..."
  if [ "${REGION}" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}"
  else
    aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}" --create-bucket-configuration LocationConstraint="${REGION}"
  fi
  aws s3api put-bucket-versioning --bucket "${BUCKET}" --versioning-configuration Status=Enabled
  echo "Bucket ${BUCKET} created and versioning enabled"
fi

echo "Ensure DynamoDB table ${TABLE} exists (region=${REGION})"
if aws dynamodb describe-table --table-name "${TABLE}" --region "${REGION}" >/dev/null 2>&1; then
  echo "DynamoDB table ${TABLE} already exists"
else
  echo "Creating DynamoDB table ${TABLE}..."
  aws dynamodb create-table \
    --table-name "${TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${REGION}"
  echo "Waiting for table to become ACTIVE..."
  aws dynamodb wait table-exists --table-name "${TABLE}" --region "${REGION}"
  echo "DynamoDB table ${TABLE} created"
fi

echo "Bootstrap complete. Configure your Terraform backend with bucket=${BUCKET}, key=<path>, dynamodb_table=${TABLE}, region=${REGION}."
