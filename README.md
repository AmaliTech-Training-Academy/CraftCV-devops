# CraftCV-devops

Terraform for the CraftCV platform. Everything lives in **eu-west-1**.

| File               | What it defines                                                  |
| ------------------ | ---------------------------------------------------------------- |
| `provider.tf`      | AWS provider, pinned to `~> 5.0`; region `eu-west-1`             |
| `variables.tf`     | VPC/subnet IDs, naming prefix, CI settings                       |
| `security_group.tf`| App firewall - inbound 80/443 only, no SSH, no Postgres          |
| `iam.tf`           | EC2 instance role for SSM Session Manager                        |
| `ec2.tf`           | The app server (Ubuntu 22.04, `t3.micro`)                        |
| `ecr.tf`           | Private Docker registry CI pushes to                             |
| `codebuild.tf`     | Phase 5 - the CI project, its service role and GitHub connection |
| `outputs.tf`       | Instance/SG IDs, CI project name, ECR URL, connection status     |

Administration is via **SSM Session Manager**, not SSH. There is no key pair
and port 22 is never open.

---

## Phase 5 - CI in AWS CodeBuild

CI builds [`AmaliTech-Training-Academy/CraftCV-backend`](https://github.com/AmaliTech-Training-Academy/CraftCV-backend).
This repo owns the infrastructure; the app repo owns `buildspec.yml` and
`scripts/quality-gates.sh`.

```
push / PR on CraftCV-backend
        │  (webhook, via the AWS Connector GitHub App)
        ▼
craftcv-backend-ci  ── CodeBuild, eu-west-1, privileged_mode = true
        │
        ├─ scripts/quality-gates.sh   ruff · black · bandit · django checks
        │                             · migration drift · pytest ≥ 80% cov
        ├─ docker build               (the image must actually build)
        └─ docker push                only on a green push to main
                ▼
        ECR  craftcv-backend:<12-char commit sha>
```

### Why a CodeConnections connection

`aws_codeconnections_connection` is backed by the AWS Connector GitHub App.
AWS mints a short-lived installation token per build, so no personal access
token is stored in Secrets Manager, in the project, or on a developer laptop -
and CI does not break when whoever created it leaves the organization.

### Docker support

`docker build` needs a Docker daemon inside the build container. Two settings
in `codebuild.tf` provide it:

- `environment.privileged_mode = true` - starts the daemon.
- `aws/codebuild/standard:7.0` - ships the Docker CLI and Python 3.11.

`cache { type = "LOCAL" }` with `LOCAL_DOCKER_LAYER_CACHE` keeps warm layers
between builds, so repeat builds do not re-download every base image. Local
caching means no S3 bucket to provision or pay for.

### The service role

`craftcv-codebuild-role` is written statement by statement rather than using
an AWS managed policy. Every statement is scoped to an exact ARN except three
where AWS supports no resource-level permission (`ecr:GetAuthorizationToken`,
`ec2:DescribeInstances`, and reading an SSM command result whose ID cannot be
known in advance). The trust policy additionally carries `aws:SourceArn` /
`aws:SourceAccount` conditions so the role can only be assumed on behalf of
this one build project.

It already includes the `ssm:SendCommand` permission the Phase 6 deploy needs,
scoped to the single app instance and the `AWS-RunShellScript` document. That
keeps the deploy keyless too - no SSH, consistent with `security_group.tf`.

### Applying it

The GitHub App handshake cannot be automated: Terraform can create a
connection only in `PENDING` state, and AWS rejects the source-credential and
webhook API calls until it is `AVAILABLE`. So this is a two-stage apply.

```bash
# Stage 1 - create the project, role, ECR repo and a PENDING connection
terraform init
terraform apply

# Authorize it once, by hand:
#   Console -> Developer Tools -> Settings -> Connections
#   -> craftcv-github -> "Update pending connection"
#   -> install the AWS Connector app into AmaliTech-Training-Academy
terraform output github_connection_status    # wait for AVAILABLE

# Stage 2 - register the credential and attach the webhook
terraform apply -var 'github_connection_authorized=true'
```

Persist the flag in a `terraform.tfvars` so it is not forgotten:

```hcl
github_connection_authorized = true
```

### Running the gates

Locally, in CraftCV-backend:

```bash
pip install -r requirements-dev.txt
./scripts/quality-gates.sh
```

In CI, `buildspec.yml` invokes that exact script - the gates are defined once,
so a green local run and a green build mean the same thing. Trigger one by
hand with:

```bash
aws codebuild start-build \
  --project-name "$(terraform output -raw codebuild_project_name)" \
  --region eu-west-1
```

Results, including the pytest and coverage reports, appear under **Report
groups** in the CodeBuild console. Logs go to
`/aws/codebuild/craftcv-backend-ci` with 30-day retention.

### Making the gates enforceable

`report_build_status = true` posts the result back as a commit status on the
pull request. Turn that into a merge block in GitHub: **Settings → Branches →
`main`** → require the `AWS CodeBuild craftcv-backend-ci` status check.
