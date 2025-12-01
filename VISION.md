# Reusable CloudFormation Modules and Self-Contained Application Stacks

## Overview

The objective is to establish an infrastructure pattern in which common AWS infrastructure capabilities are implemented once, packaged as reusable **CloudFormation modules**, and published into the CloudFormation Registry for use by ordinary CloudFormation application stacks.

The system deliberately separates two responsibilities:

**Terraform acts as the module publishing and bootstrap layer.**

**CloudFormation remains the application infrastructure layer.**

Terraform is responsible for discovering CloudFormation modules stored in the repository, packaging those modules, placing their packages in S3, and registering new versions with the CloudFormation Registry.

Application developers do not need Terraform in order to consume those components. Once registered, the modules appear as normal CloudFormation resource types such as:

```yaml
Company::S3::ObjectProvider::MODULE
```

Application templates can therefore remain entirely CloudFormation-based.

The initial example for this architecture is a fully self-contained static website stack consisting of:

```text
CloudFront
    │
    ▼
Private S3 Bucket
    │
    └── index.html

S3ObjectProvider
    ├── Lambda
    └── IAM Role

Custom::S3Object
    │
    └── invokes S3ObjectProvider
```

The application stack creates all of its infrastructure and also creates its own static website contents. It requires no separately deployed website artifacts.

---

# 1. Architectural Goals

The primary goal is to create an internal library of reusable CloudFormation building blocks.

Instead of repeatedly writing infrastructure such as:

```text
IAM role
Lambda
Lambda permissions
custom-resource plumbing
resource configuration
```

every application can reference a higher-level company-provided module.

For example:

```yaml
Resources:
  S3ObjectProvider:
    Type: Company::S3::ObjectProvider::MODULE
```

CloudFormation expands the module into its constituent resources during stack processing.

CloudFormation also allows resources inside a module to be referenced from the containing template. For example, if the module contains a Lambda resource named `Handler`, the parent template can access it using a qualified logical resource name such as:

```yaml
!GetAtt S3ObjectProvider.Handler.Arn
```

This behavior is explicitly supported by CloudFormation's module resource-reference mechanism.

The result is an abstraction layer that is reusable while retaining normal CloudFormation behavior.

---

# 2. Why Terraform Is Used for Module Publishing

CloudFormation modules must be registered before another CloudFormation stack can use them.

A module is developed as a CloudFormation CLI module project containing a template fragment and a generated schema. AWS's normal module development workflow uses `cfn init`, a `fragments` directory, validation/schema generation, and registration.

The resulting module package must ultimately be available through S3 for Registry registration. AWS's module-registration API expects an S3-backed package containing the module template fragment and schema.

This produces an awkward bootstrap problem if CloudFormation itself is also expected to manage the entire module publishing process:

```text
module source
    ↓
generate package
    ↓
zip package
    ↓
upload package to S3
    ↓
register module
```

Terraform is particularly well suited to this outer lifecycle because it can operate on collections of modules using `for_each`, create deterministic archives, upload those archives to S3, and register the resulting CloudFormation types.

The HashiCorp AWS provider exposes `aws_cloudformation_type`, which supports:

```hcl
type = "MODULE"
```

and registers a package referenced by `schema_handler_package`.

Therefore the desired architecture is:

```text
                      MODULE DEVELOPMENT

                     Git repository
                          │
              ┌───────────┴───────────┐
              │                       │
      s3-object-provider        another-module
              │                       │
              └───────────┬───────────┘
                          │
                          ▼
                       Terraform
                          │
                  package / archive
                          │
                          ▼
                    Artifact S3 bucket
                          │
                          ▼
                  CloudFormation Registry
                          │
             ┌────────────┴────────────┐
             │                         │
Company::S3::ObjectProvider::MODULE   ...
```

Terraform exists only at this publishing layer.

It does not need to own the infrastructure created by applications.

---

# 3. Repository Structure

A repository could be organized approximately as follows:

```text
infrastructure-components/
│
├── terraform/
│   ├── main.tf
│   ├── modules.tf
│   ├── storage.tf
│   ├── variables.tf
│   └── outputs.tf
│
├── modules/
│   │
│   ├── s3-object-provider/
│   │   ├── module.json
│   │   ├── schema.json
│   │   └── fragments/
│   │       └── fragment.yaml
│   │
│   ├── example-other-module/
│   │   ├── module.json
│   │   ├── schema.json
│   │   └── fragments/
│   │       └── fragment.yaml
│   │
│   └── ...
│
└── examples/
    └── static-website/
        └── template.yaml
```

Each directory beneath `modules/` represents one independently registered CloudFormation module.

For example:

```text
modules/s3-object-provider
```

corresponds to:

```text
Company::S3::ObjectProvider::MODULE
```

The module schema should be generated and validated using the CloudFormation CLI whenever the module source changes. AWS documents `cfn validate` as regenerating the module schema from the template fragment.

A useful operational boundary is:

```text
CloudFormation CLI
    = module authoring / validation

Terraform
    = packaging / publishing / registration
```

This avoids making Terraform responsible for understanding how a CloudFormation module schema is constructed.

The generated schema can be committed alongside the module fragment, allowing the Terraform deployment itself to remain deterministic.

---

# 4. Terraform Module Discovery

Terraform can define the modules centrally:

```hcl
locals {
  cloudformation_modules = {
    s3_object_provider = {
      name = "Company::S3::ObjectProvider::MODULE"
      path = "${path.module}/../modules/s3-object-provider"
    }

    # Future modules:
    #
    # secret_provider = {
    #   name = "Company::Secrets::Provider::MODULE"
    #   path = "${path.module}/../modules/secret-provider"
    # }
  }
}
```

Alternatively, the repository can establish naming conventions that allow the directory hierarchy itself to drive this configuration.

The important property is that Terraform sees the components as a collection.

That allows the same publishing machinery to operate against every module:

```hcl
for_each = local.cloudformation_modules
```

Adding another module consequently becomes primarily a matter of adding another source directory rather than copying publishing infrastructure.

---

# 5. Module Artifact Storage

Terraform provisions an S3 bucket dedicated to CloudFormation extension artifacts.

Conceptually:

```hcl
resource "aws_s3_bucket" "cloudformation_modules" {
  bucket = var.module_artifact_bucket
}
```

The bucket is not application infrastructure.

It belongs to the platform/bootstrap environment and contains versioned build artifacts for the reusable component library.

The contents might resemble:

```text
s3://company-cloudformation-modules/
│
├── Company-S3-ObjectProvider/
│   ├── 581c33e....zip
│   ├── c1348aa....zip
│   └── ...
│
├── Company-Secrets-Provider/
│   └── ...
│
└── ...
```

Artifact keys should preferably be content-addressed rather than named simply `latest.zip`.

For example:

```text
Company-S3-ObjectProvider/<source-hash>.zip
```

This has several advantages.

An existing registered module version always points at immutable content.

Changing a module naturally produces a new package.

Terraform sees the package URL change and therefore registers a new CloudFormation module version.

Historic packages remain available for troubleshooting and rollback.

---

# 6. Packaging Modules with Terraform

Terraform can use an archive mechanism to package each module directory.

Conceptually:

```hcl
data "archive_file" "module" {
  for_each = local.cloudformation_modules

  type        = "zip"
  source_dir  = each.value.path
  output_path = "${path.module}/build/${each.key}.zip"
}
```

Each module then produces its own package:

```text
modules/s3-object-provider/
              │
              ▼
s3-object-provider.zip
```

The package is uploaded through `aws_s3_object`, which is the current AWS provider resource for managing S3 objects.

Conceptually:

```hcl
resource "aws_s3_object" "module_package" {
  for_each = local.cloudformation_modules

  bucket = aws_s3_bucket.cloudformation_modules.id

  key = format(
    "modules/%s/%s.zip",
    each.key,
    data.archive_file.module[each.key].output_sha256
  )

  source = data.archive_file.module[each.key].output_path
}
```

This makes the deployment pipeline approximately:

```text
Terraform evaluates modules/
          │
          ▼
     archive_file
          │
       ┌──┴──┐
       ▼     ▼
 module A   module B
   .zip      .zip
       │     │
       └──┬──┘
          ▼
          S3
```

---

# 7. Registering Modules from Terraform

The uploaded module package can then be registered directly using the Terraform AWS provider.

Conceptually:

```hcl
resource "aws_cloudformation_type" "module" {
  for_each = local.cloudformation_modules

  type      = "MODULE"
  type_name = each.value.name

  schema_handler_package = format(
    "s3://%s/%s",
    aws_s3_object.module_package[each.key].bucket,
    aws_s3_object.module_package[each.key].key
  )

  lifecycle {
    create_before_destroy = true
  }
}
```

The AWS provider's `aws_cloudformation_type` resource manages a CloudFormation Registry type version and explicitly supports both `RESOURCE` and `MODULE` as type values.

The `create_before_destroy` lifecycle is important because the resource represents an individual Registry version. HashiCorp notes that destroying it deprecates that version and recommends `create_before_destroy` for redeployments.

The lifecycle therefore becomes:

```text
Change fragment.yaml
        │
        ▼
Regenerate / validate schema
        │
        ▼
terraform apply
        │
        ├── creates new ZIP
        │
        ├── uploads new S3 object
        │
        └── registers new module version
```

Terraform state now tracks which Registry module versions belong to the platform deployment.

One item needs an explicit policy: **which registered version is the default version**.

CloudFormation supports multiple active versions and separately tracks the default version. CloudFormation itself exposes `AWS::CloudFormation::ModuleDefaultVersion` for changing it.

The Terraform `aws_cloudformation_type` resource exposes information such as `version_id`, `default_version_id`, and `is_default_version`, but its documented arguments do not currently expose a direct "make this version default" switch.

Therefore the publishing layer should explicitly implement default-version promotion.

For example, a small Terraform-controlled operation can execute the equivalent CloudFormation API operation after registration:

```text
Register new module version
          │
          ▼
Run validation / acceptance tests
          │
          ▼
SetTypeDefaultVersion
          │
          ▼
new version becomes production default
```

The key architectural point is that **registration and promotion should be considered separate operations**, even if both occur during the same CI/Terraform deployment.

That separation also provides a natural future safety mechanism in which a module can be registered first, tested, and only then promoted.

---

# 8. The Initial S3 Object Provider Module

The first reusable component is:

```text
Company::S3::ObjectProvider::MODULE
```

This module is not itself an S3 object.

It is a reusable **custom-resource provider**.

Its purpose is to create the infrastructure required for ordinary CloudFormation custom resources to perform S3 object operations.

Its internal structure is approximately:

```text
Company::S3::ObjectProvider::MODULE
│
├── AWS::IAM::Role
│
└── AWS::Lambda::Function
```

The Lambda implements the traditional CloudFormation custom-resource callback protocol.

It accepts properties such as:

```text
Bucket
Key
Body
ContentType
CacheControl
```

and performs the appropriate operation depending on the CloudFormation request type.

### Create

```text
PutObject
```

### Update

```text
PutObject
```

possibly deleting the previous key if the bucket/key identity changed.

### Delete

```text
DeleteObject
```

The provider therefore gives application stacks a lightweight resource abstraction:

```yaml
Type: Custom::S3Object
```

without registering `Custom::S3Object` as a CloudFormation Registry resource type.

It remains an ordinary Lambda-backed CloudFormation custom resource.

---

# 9. Why the Provider Is Separate from the Object

The provider module intentionally does **not** contain a `Custom::S3Object` resource.

If it did, every module instance would create:

```text
IAM role
Lambda
S3 custom resource
```

Using the module twice would therefore produce:

```text
Object A
├── Role A
├── Lambda A
└── Custom Resource A

Object B
├── Role B
├── Lambda B
└── Custom Resource B
```

That is unnecessary.

Instead, the stack creates the provider exactly once:

```yaml
S3ObjectProvider:
  Type: Company::S3::ObjectProvider::MODULE
```

and then creates N custom-resource instances using the same provider:

```text
                    ┌── index.html
                    │
S3ObjectProvider ───┼── app.js
                    │
                    ├── styles.css
                    │
                    └── config.json
```

Thus the resulting infrastructure is:

```text
1 IAM Role
1 Lambda
N Custom::S3Object resources
```

rather than:

```text
N IAM Roles
N Lambdas
N Custom::S3Object resources
```

---

# 10. Referencing the Module's Lambda

Suppose the provider module contains:

```yaml
Resources:
  HandlerRole:
    Type: AWS::IAM::Role

  Handler:
    Type: AWS::Lambda::Function
```

The application can reference the Lambda contained inside the module:

```yaml
!GetAtt S3ObjectProvider.Handler.Arn
```

CloudFormation supports these qualified references to resources within modules.

That ARN becomes the `ServiceToken` for any number of custom resources:

```yaml
IndexHtml:
  Type: Custom::S3Object
  Properties:
    ServiceToken: !GetAtt S3ObjectProvider.Handler.Arn
```

This avoids requiring a separate output mechanism solely to expose the provider ARN.

---

# 11. Example: Completely Self-Contained Static Website

Once the provider module has been registered by the Terraform platform deployment, an application stack can build a complete website using only CloudFormation.

Conceptually:

```text
CloudFormation Application Stack
│
├── WebsiteBucket
│
├── CloudFrontOriginAccessControl
│
├── CloudFrontDistribution
│
├── WebsiteBucketPolicy
│
├── S3ObjectProvider
│   │
│   ├── HandlerRole
│   └── Handler Lambda
│
└── IndexHtml
    └── Custom::S3Object
```

No domain name is required.

CloudFront automatically provides a hostname similar to:

```text
d123example.cloudfront.net
```

The stack can return:

```text
https://d123example.cloudfront.net
```

as an output.

---

# 12. Static Website CloudFormation Template

A representative application template is:

```yaml
AWSTemplateFormatVersion: "2010-09-09"

Resources:
  WebsiteBucket:
    Type: AWS::S3::Bucket
    Properties:
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        IgnorePublicAcls: true
        BlockPublicPolicy: true
        RestrictPublicBuckets: true

  OriginAccessControl:
    Type: AWS::CloudFront::OriginAccessControl
    Properties:
      OriginAccessControlConfig:
        Name: !Sub "${AWS::StackName}-oac"
        Description: Access from CloudFront to the private website bucket
        OriginAccessControlOriginType: s3
        SigningBehavior: always
        SigningProtocol: sigv4

  Distribution:
    Type: AWS::CloudFront::Distribution
    Properties:
      DistributionConfig:
        Enabled: true

        DefaultRootObject: index.html

        Origins:
          - Id: WebsiteOrigin
            DomainName: !GetAtt WebsiteBucket.RegionalDomainName
            OriginAccessControlId: !GetAtt OriginAccessControl.Id
            S3OriginConfig: {}

        DefaultCacheBehavior:
          TargetOriginId: WebsiteOrigin

          ViewerProtocolPolicy: redirect-to-https

          AllowedMethods:
            - GET
            - HEAD

          CachedMethods:
            - GET
            - HEAD

          ForwardedValues:
            QueryString: false
            Cookies:
              Forward: none

  WebsiteBucketPolicy:
    Type: AWS::S3::BucketPolicy
    Properties:
      Bucket: !Ref WebsiteBucket

      PolicyDocument:
        Version: "2012-10-17"

        Statement:
          - Effect: Allow

            Principal:
              Service: cloudfront.amazonaws.com

            Action:
              - s3:GetObject

            Resource: !Sub "${WebsiteBucket.Arn}/*"

            Condition:
              StringEquals:
                AWS:SourceArn: !Sub
                  - "arn:${AWS::Partition}:cloudfront::${AWS::AccountId}:distribution/${DistributionId}"
                  - DistributionId: !Ref Distribution

  S3ObjectProvider:
    Type: Company::S3::ObjectProvider::MODULE
    Properties:
      BucketArn: !GetAtt WebsiteBucket.Arn

  IndexHtml:
    Type: Custom::S3Object
    Properties:
      ServiceToken: !GetAtt S3ObjectProvider.Handler.Arn

      Bucket: !Ref WebsiteBucket
      Key: index.html
      ContentType: text/html

      Body: |
        <!doctype html>
        <html lang="en">
          <head>
            <meta charset="utf-8">
            <meta
              name="viewport"
              content="width=device-width, initial-scale=1"
            >

            <title>CloudFormation Website</title>
          </head>

          <body>
            <main>
              <h1>Hello from CloudFormation</h1>

              <p>
                The infrastructure and the contents of this
                website were provisioned by the same stack.
              </p>
            </main>
          </body>
        </html>

Outputs:
  WebsiteUrl:
    Description: CloudFront website URL
    Value: !Sub "https://${Distribution.DomainName}"

  WebsiteBucket:
    Value: !Ref WebsiteBucket
```

The S3 bucket is intentionally **not configured as an S3 website endpoint**.

CloudFront accesses the ordinary S3 REST endpoint using Origin Access Control. The bucket remains private.

---

# 13. What Happens During Deployment

When this stack is created, CloudFormation evaluates approximately the following dependency graph:

```text
WebsiteBucket
      │
      ├─────────────────────┐
      │                     │
      ▼                     ▼
ObjectProvider          CloudFront OAC
      │                     │
      │                     ▼
      │                Distribution
      │                     │
      │                     ▼
      │                Bucket Policy
      │
      ▼
IndexHtml
      │
      ▼
Provider Lambda
      │
      ▼
s3:PutObject
      │
      ▼
WebsiteBucket/index.html
```

The provider Lambda receives a normal CloudFormation custom-resource `Create` request.

It writes:

```text
index.html
```

into the S3 bucket.

CloudFront then serves the object through the distribution.

The application contains no external deployment script and requires no separate website publishing job.

---

# 14. Multiple Website Objects

The same provider can be used repeatedly:

```yaml
IndexHtml:
  Type: Custom::S3Object
  Properties:
    ServiceToken: !GetAtt S3ObjectProvider.Handler.Arn
    Bucket: !Ref WebsiteBucket
    Key: index.html
    ContentType: text/html
    Body: |
      ...

Stylesheet:
  Type: Custom::S3Object
  Properties:
    ServiceToken: !GetAtt S3ObjectProvider.Handler.Arn
    Bucket: !Ref WebsiteBucket
    Key: styles.css
    ContentType: text/css
    Body: |
      body {
        font-family: sans-serif;
      }

ApplicationJavascript:
  Type: Custom::S3Object
  Properties:
    ServiceToken: !GetAtt S3ObjectProvider.Handler.Arn
    Bucket: !Ref WebsiteBucket
    Key: app.js
    ContentType: application/javascript
    Body: |
      console.log("Hello");
```

The stack still contains only:

```text
1 provider Lambda
1 provider IAM role
```

while all three `Custom::S3Object` resources share that provider.

---

# 15. Resource Lifecycle

An important property of this system is that S3 objects become genuine members of the CloudFormation lifecycle, even though they are implemented through a traditional custom resource.

For example, changing:

```yaml
Body: |
  <h1>Version One</h1>
```

to:

```yaml
Body: |
  <h1>Version Two</h1>
```

causes CloudFormation to send an `Update` event to the provider.

The provider writes the new object.

Deleting the application stack sends a `Delete` event.

The provider deletes the corresponding S3 object.

The infrastructure and its bootstrap contents are consequently managed together:

```text
CREATE STACK
    ↓
create bucket
create distribution
create provider
create index.html


UPDATE STACK
    ↓
update index.html


DELETE STACK
    ↓
delete index.html
delete provider
delete distribution
delete bucket
```

Correct CloudFormation dependency ordering must be maintained so that the object is deleted while the provider Lambda and bucket still exist.

---

# 16. CloudFront Caching

One concern exists outside the S3 object's lifecycle: CloudFront caching.

Updating:

```text
index.html
```

changes the S3 object immediately, but an existing CloudFront edge cache may continue serving the previous version.

For the initial simple implementation, this can be dealt with through conservative cache settings.

A future reusable component could add a second capability such as:

```text
Company::CloudFront::InvalidationProvider::MODULE
```

with an associated:

```yaml
Custom::CloudFrontInvalidation
```

resource.

That would allow application deployments to perform:

```text
Update website content
        │
        ▼
PutObject
        │
        ▼
CreateInvalidation /*
```

without requiring application-specific scripts.

---

# 17. Evolution into an Internal CloudFormation Component Library

The S3 object provider is only the first example.

The same architecture can support reusable providers such as:

```text
Company::S3::ObjectProvider::MODULE

Company::CloudFront::InvalidationProvider::MODULE

Company::Secrets::GeneratorProvider::MODULE

Company::Route53::RecordProvider::MODULE

Company::Deployment::ArtifactProvider::MODULE
```

It can also support non-custom-resource composition modules such as:

```text
Company::Lambda::Function::MODULE

Company::SQS::StandardQueue::MODULE

Company::Application::ServiceRole::MODULE

Company::CloudFront::StaticOrigin::MODULE
```

The important distinction is that modules can encapsulate either:

```text
ordinary AWS resources
```

or:

```text
the infrastructure necessary to support
traditional Lambda-backed custom resources
```

depending on the abstraction being created.

---

# 18. Platform Versus Application Ownership

A strict ownership boundary prevents Terraform and CloudFormation from fighting over the same resources.

## Terraform owns

```text
CloudFormation module source packaging
Module artifact S3 bucket
Module ZIP objects
CloudFormation Registry module versions
Default module version promotion
```

## CloudFormation application stacks own

```text
S3 website buckets
CloudFront distributions
OACs
bucket policies
provider module instances
provider Lambda functions
provider IAM roles
Custom::S3Object instances
website contents
```

Terraform never owns the Lambda produced by:

```text
Company::S3::ObjectProvider::MODULE
```

It only owns the **definition of the module** registered in the Registry.

CloudFormation owns each concrete instance created from that definition.

This distinction is central to the architecture.

---

# 19. Full Lifecycle

The complete system can therefore be visualized as two pipelines.

## Component publishing pipeline

```text
Developer
    │
    ▼
modules/
    │
    ▼
CloudFormation CLI validation
    │
    ▼
fragment + schema
    │
    ▼
Terraform
    │
    ├── archive module
    │
    ├── hash module
    │
    ├── upload ZIP
    │
    ├── register MODULE version
    │
    └── promote version
    │
    ▼
CloudFormation Registry
```

## Application deployment pipeline

```text
Application template
        │
        ▼
CloudFormation
        │
        ├── AWS resources
        │
        └── Company::*::MODULE
                 │
                 ▼
          module expansion
                 │
                 ▼
        concrete AWS resources
```

These pipelines interact only through the CloudFormation Registry.

That is a particularly useful separation because application stacks don't need to understand where the modules came from.

---

# 20. Multi-Region Considerations

CloudFormation extension registration is Region-specific. AWS notes that extensions need to be registered in each Region in which they will be used.

Terraform is useful here because the same module collection can be published using multiple AWS provider aliases.

Conceptually:

```text
Module sources
      │
      ▼
Terraform
      │
      ├── us-east-1
      │
      ├── us-east-2
      │
      ├── ca-central-1
      │
      └── eu-west-1
      │
      ▼
same CloudFormation module library
available in every supported Region
```

This provides a straightforward path toward an organization-wide component catalog.

---

# 21. Versioning Strategy

Module versions should be treated as immutable.

A change to a module should produce:

```text
new source
    ↓
new hash
    ↓
new ZIP
    ↓
new S3 key
    ↓
new CloudFormation Registry version
```

Existing registered versions should not have their package contents replaced.

CloudFormation Registry resources naturally model versions, and the Terraform AWS provider's CloudFormation type resource exposes the registered version identifier and default-version information.

A deployment can therefore eventually support controlled promotion:

```text
v1
 │
 ├── production default
 │
 ▼
register v2
 │
 ▼
test v2
 │
 ▼
promote v2
 │
 ▼
v2 production default
```

This is preferable to treating the module registry as an unversioned mutable store.

---

# 22. Security Model

The S3 object provider should follow least privilege.

For the static website example, the module can accept:

```yaml
Properties:
  BucketArn: !GetAtt WebsiteBucket.Arn
```

and build its role around:

```text
${BucketArn}/*
```

rather than:

```text
arn:aws:s3:::*
```

The Lambda can then perform only the operations required by the custom resource, approximately:

```text
s3:PutObject
s3:DeleteObject
```

on that bucket.

This means the provider module is reusable while each concrete module instance receives permissions appropriate to its application stack.

The CloudFront side likewise keeps the bucket private and grants object-read access to the CloudFront distribution rather than exposing the S3 bucket publicly.

---

# 23. Why This Architecture Is Useful

The architecture creates a middle ground between raw CloudFormation and a full custom CloudFormation Registry resource implementation.

For capabilities where native CloudFormation is missing a small imperative operation, creating an entire Registry resource provider can be excessive.

A lightweight provider module gives the organization:

```text
reusability
standardized IAM
standardized Lambda implementation
central maintenance
normal CloudFormation lifecycle
simple application templates
```

without forcing every application to reproduce:

```text
Lambda
IAM
ServiceToken plumbing
handler implementation
```

At the same time, the application stack remains transparent.

The module does not create a second stack.

It expands into resources that belong directly to the consuming stack.

---

# 24. Target Developer Experience

The long-term developer experience should be extremely simple.

A developer writing CloudFormation should be able to think in terms of:

```yaml
Resources:
  ObjectProvider:
    Type: Company::S3::ObjectProvider::MODULE
    Properties:
      BucketArn: !GetAtt Bucket.Arn

  Index:
    Type: Custom::S3Object
    Properties:
      ServiceToken: !GetAtt ObjectProvider.Handler.Arn
      Bucket: !Ref Bucket
      Key: index.html
      ContentType: text/html
      Body: |
        <h1>Hello</h1>
```

They should not need to understand:

```text
how the module is packaged
where its ZIP lives
how Registry registration works
which Terraform deployment published it
how its schema was generated
```

Those are platform concerns.

---

# 25. Final Architecture

The resulting system is:

```text
┌─────────────────────────────────────────────────────┐
│                PLATFORM REPOSITORY                  │
│                                                     │
│  modules/                                           │
│    s3-object-provider/                              │
│    cloudfront-invalidation-provider/                │
│    ...                                              │
│                                                     │
│                      │                              │
│                      ▼                              │
│                  Terraform                          │
│                      │                              │
│          package + upload + register                │
│                      │                              │
│                      ▼                              │
│            CloudFormation Registry                  │
│                                                     │
└──────────────────────┬──────────────────────────────┘
                       │
                       │ reusable module definitions
                       ▼
┌─────────────────────────────────────────────────────┐
│                 APPLICATION STACK                   │
│                                                     │
│             CloudFormation template                 │
│                      │                              │
│      ┌───────────────┼────────────────┐             │
│      ▼               ▼                ▼             │
│  S3 Bucket       CloudFront      ObjectProvider     │
│                                      │              │
│                               ┌──────┴──────┐       │
│                               ▼             ▼       │
│                           IAM Role       Lambda      │
│                                               │     │
│                                               ▼     │
│                                      Custom::S3Object│
│                                               │     │
│                                               ▼     │
│                                          index.html │
│                                                     │
└─────────────────────────────────────────────────────┘
```

The key principle is:

**Terraform publishes capabilities. CloudFormation consumes capabilities.**

Terraform handles the awkward bootstrap mechanics of discovering, packaging, uploading, versioning, and registering an arbitrary collection of modules.

CloudFormation remains the mechanism through which actual application infrastructure is defined and deployed.

The first proof of concept is a static CloudFront website whose S3 content is itself created by CloudFormation through a reusable S3 object provider module.

Once that works, the same publishing mechanism becomes the foundation for a broader internal CloudFormation component library.
