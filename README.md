# aws-module-flow-for-simple-s3-object

> [!WARNING]
> **AI-authored:** This change was autonomously planned and implemented by an AI software factory from a human-authored specification, with possible subsequent human review or modification.

Explores authoring a reusable CloudFormation module, packaging and registering it via Terraform, that provides a Lambda-backed provider for `Custom::S3Object` resources.

```bash
cd modules/s3-object-provider
cfn validate
cfn submit --dry-run

cd ../../terraform
terraform init
terraform apply

aws cloudformation describe-type --type MODULE \
  --type-name Company::S3::ObjectProvider::MODULE --region us-east-1

aws cloudformation deploy --template-file examples/static-website/template.yaml \
  --stack-name s3-object-module-example --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND
# curl the WebsiteUrl output, then update IndexHtml Body, update-stack, curl again
aws cloudformation delete-stack --stack-name s3-object-module-example
```

## Notes

- Simple setup leveraging the modules for a reusable interactions with S3
