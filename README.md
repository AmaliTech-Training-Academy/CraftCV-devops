# CraftCV-devops

Terraform for the CraftCV platform. Everything lives in **eu-west-1**.

| File               | What it defines                                                  |
| ------------------ | ---------------------------------------------------------------- |
| `provider.tf`      | AWS provider `~> 5.0`, region `eu-west-1`, and the S3 backend    |
| `variables.tf`     | VPC/subnet IDs, naming prefix, CI settings                       |
| `security_group.tf`| App firewall - inbound 80/443 only, no SSH, no Postgres          |
| `iam.tf`           | EC2 instance role for SSM Session Manager                        |
| `ec2.tf`           | The app server (Ubuntu 22.04, `t3.micro`)                        |
| `ecr.tf`           | Private Docker registry CI pushes to                             |
| `codebuild.tf`     | Phase 5 - the CI project, its service role and GitHub connection |
| `outputs.tf`       | Instance/SG IDs, CI project name, ECR URL, connection status     |

Administration is via **SSM Session Manager**, not SSH. There is no key pair
and port 22 is never open.

## State

State lives in S3, not in this repository:

```
s3://craftcv-tfstate-897729111286/craftcv-devops/terraform.tfstate
```

It used to be a `terraform.tfstate` committed alongside the code. That could
not be locked, went stale the moment anyone applied, and put a file that can
contain secrets into git history. The old file is still in the history - treat
anything it held as needing rotation, not as private.

Locking is S3-native (`use_lockfile = true`, conditional writes), which needs
Terraform >= 1.10 and replaces the DynamoDB lock table older guides describe.
One less resource to run, and DynamoDB locking is deprecated.

### Bootstrapping the bucket

The bucket is created outside Terraform on purpose: it has to exist before
Terraform can store state in it, and managing it from the state it holds makes
the configuration impossible to destroy cleanly. To recreate it:

```bash
BUCKET=craftcv-tfstate-897729111286

aws s3api create-bucket --bucket "$BUCKET" --region eu-west-1 \
  --create-bucket-configuration LocationConstraint=eu-west-1

aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

A bucket policy denying `aws:SecureTransport = false` is also applied, so the
state can only move over TLS. Versioning is what lets you roll back a bad
apply, so do not turn it off.

### Running Terraform on this machine

Two things bite on a Windows host with the repo on the WSL filesystem:

- **Run Terraform from inside WSL.** The Windows build fails with
  `Error acquiring the state lock ... Incorrect function`, because Windows
  file locking does not work over the `\\wsl.localhost` share.
- **Export credentials first.** `aws login` stores short-lived credentials
  under `~/.aws/login/`, which the AWS CLI reads but Terraform's SDK does not.
  Prefix commands with:

  ```bash
  eval "$(aws configure export-credentials --format env)"
  ```

---

## Phase 5 - CI in AWS CodeBuild

CI builds [`AmaliTech-Training-Academy/CraftCV-backend`](https://github.com/AmaliTech-Training-Academy/CraftCV-backend).
This repo owns the infrastructure; the app repo owns `buildspec.yml` and
its own `scripts/check.sh`.

```
push to develop/main, or PR targeting either, on CraftCV-backend
        │  (webhook, via the AWS Connector GitHub App)
        ▼
craftcv-backend-ci  ── CodeBuild, eu-west-1, privileged_mode = true
        │
        ├─ sh scripts/check.sh lint    ruff check + ruff format --check
        ├─ sh scripts/check.sh build   django checks + migration drift
        ├─ sh scripts/check.sh test    manage.py test (SQLite)
        ├─ docker build                the image must actually build
        ├─ docker run … manage.py check   checks pass inside the image too
        └─ docker push                 only on a green push to develop/main
                ▼
        ECR  craftcv-backend:<12-char commit sha>
```

`scripts/check.sh` is CraftCV-backend's own canonical gate - its Git hooks and
`.github/workflows/ci.yml` already call it. CodeBuild calls the same entry
point rather than redefining the gates, which is what keeps a green local run,
a green Actions run and a green build meaning the same thing.

### How CodeBuild authenticates to GitHub

The organization-approved method is an AWS CodeConnections GitHub App
connection, and that is what this was built with first. It did not survive
contact with reality: installing the AWS Connector app into
`AmaliTech-Training-Academy` needs an organization owner, and AWS refuses to
create the webhook while the connection sits at `PENDING`:

```
InvalidInputException: Connection craftcv-github is not available
```

So CodeBuild authenticates with a GitHub personal access token held in
Secrets Manager (`auth_type = "SECRETS_MANAGER"`). Terraform references only
the secret's ARN, so the token never enters the configuration, the state file
or this repository, and rotating it is an update to the secret with no
Terraform run at all.

**The tradeoff is real.** A PAT belongs to a person: CI breaks silently when
that account is deprovisioned or the token expires. Prefer a machine account's
token, diary the expiry, and move back to a connection if an owner ever
approves the app - the code for it is in this repo's history.

#### The secret's format

CodeBuild does not accept a bare token. The secret must hold this exact JSON,
or `CreateWebhook` fails with `was not in the expected json format`:

```json
{"ServerType":"GITHUB","AuthType":"PERSONAL_ACCESS_TOKEN","Token":"ghp_..."}
```

The token needs the `repo` and `admin:repo_hook` scopes - `repo` to clone the
private repository and post commit statuses, `admin:repo_hook` to register the
webhook. It must be a classic token; fine-grained tokens against an
organization's repositories generally need owner approval, which is the
problem we are working around.

To create or rotate it, in your own terminal (never through a tool that logs
its input):

```bash
read -rs -p "Paste GitHub PAT: " PAT && echo
python3 -c "import json,os;print(json.dumps({'ServerType':'GITHUB','AuthType':'PERSONAL_ACCESS_TOKEN','Token':os.environ['PAT']}))"   > /tmp/tok.json
PAT="$PAT" aws secretsmanager put-secret-value --secret-id craftcv/github-token   --region eu-west-1 --secret-string file:///tmp/tok.json
shred -u /tmp/tok.json; unset PAT
```

#### A first apply may need one retry

CodeBuild checks that the service role can read the secret at the moment
`CreateWebhook` runs. On a from-scratch apply that happens a second after the
IAM policy is written, and IAM is eventually consistent, so it can fail with:

```
Project service role does not have access to retrieve secret ...
```

Nothing is wrong - run `terraform apply` again and it succeeds.

### Docker support

`docker build` needs a Docker daemon inside the build container. Two settings
in `codebuild.tf` provide it:

- `environment.privileged_mode = true` - starts the daemon.
- `aws/codebuild/standard:8.0` - ships the Docker CLI and Python 3.12,
  matching the app's Dockerfile and its Actions workflow.

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
pip install -r requirements.txt -r requirements-dev.txt
sh scripts/check.sh all          # or: lint | build | test
```

`buildspec.yml` invokes those same three subcommands. Trigger a build by hand
with:

```bash
aws codebuild start-build \
  --project-name "$(terraform output -raw codebuild_project_name)" \
  --region eu-west-1
```

Logs go to `/aws/codebuild/craftcv-backend-ci` with 30-day retention. There is
no **Report groups** entry: `manage.py test` emits no JUnit XML, so failures
are read from the log. The role already carries the report permissions, so
adding a runner that does emit XML needs only a `reports:` block in
`buildspec.yml`.

### Making the gates enforceable

`report_build_status = true` posts the result back as a commit status on the
pull request. Turn that into a merge block in GitHub: **Settings → Branches →
`develop`** → require the `AWS CodeBuild craftcv-backend-ci` status check.

### Overlap with GitHub Actions

CraftCV-backend still has `.github/workflows/ci.yml` running the same three
gates. Both will run on every PR until one is retired - deliberate during the
migration, since it proves the CodeBuild project agrees with Actions before
anyone depends on it. Delete the workflow once the required status check has
been switched over.
