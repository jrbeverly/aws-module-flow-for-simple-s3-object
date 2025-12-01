terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

resource "aws_s3_bucket" "cloudformation_modules" {
  bucket = "company-cloudformation-module-artifacts"
}

data "archive_file" "s3_object_provider" {
  type        = "zip"
  source_dir  = "${path.module}/../modules/s3-object-provider"
  output_path = "${path.module}/s3-object-provider.zip"
}

resource "aws_s3_object" "s3_object_provider" {
  bucket = aws_s3_bucket.cloudformation_modules.id
  key    = "Company-S3-ObjectProvider/${data.archive_file.s3_object_provider.output_sha256}.zip"
  source = data.archive_file.s3_object_provider.output_path
}

resource "aws_cloudformation_type" "s3_object_provider" {
  type      = "MODULE"
  type_name = "Company::S3::ObjectProvider::MODULE"

  schema_handler_package = "s3://${aws_s3_object.s3_object_provider.bucket}/${aws_s3_object.s3_object_provider.key}"

  lifecycle {
    create_before_destroy = true
  }
}

resource "null_resource" "set_default_version" {
  triggers = {
    version_arn = aws_cloudformation_type.s3_object_provider.arn
  }

  provisioner "local-exec" {
    command = "aws cloudformation set-type-default-version --arn ${aws_cloudformation_type.s3_object_provider.arn} --region us-east-1"
  }
}
