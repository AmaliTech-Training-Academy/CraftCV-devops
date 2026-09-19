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
| `deploy.tf`        | Phase 6 - the SSM document that deploys to the instance          |
| `codebuild_frontend.tf` | CI for CraftCV-frontend                                    |
| `deploy_frontend.tf`    | SSM document that publishes the frontend                   |
| `frontend_artifacts.tf` | Private S3 bucket the frontend build is shipped through    |
| `schedule.tf`      | Sandbox start/stop schedule, for cost control                    |
| `eip.tf`           | Elastic IP, so the address survives the nightly stop             |
| `backup.tf`        | Nightly database dump to S3, and the restore document            |
| `pdf_storage.tf`   | Private S3 bucket the generated CV PDFs are cached in            |
| `budget.tf`        | Spend alerts, so a runaway is noticed in days not months         |
| `scripts/`         | The deploy shell script the SSM document runs                    |
| `outputs.tf`       | Instance/SG IDs, CI project name, ECR URL, deploy document       |

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

### GitHub Actions is retired

CraftCV-backend has no workflows left. `ci.yml`, `deploy.yml` and
`repository-standards.yml` were all removed; only
`.github/pull_request_template.md` remains.

CodeBuild runs everything, including the branch-name, commit-subject and
whitespace checks that `repository-standards.yml` used to do. Those run as the
first step of the `install` phase in `buildspec.yml`, on pull request builds
only, and call the repository's own `scripts/validate-conventions.sh` - the
same script the Git hooks call, so a rejected push and a red build mean the
same thing.

This is why the project clones with `git_clone_depth = 0`: comparing a pull
request's commits against its base branch needs real history, and a shallow
clone has none.

**Branch protection needs updating.** Any required status check still named
after an Actions job (`lint`, `build-and-test`, `docker`,
`repository-standards`) will never report again, and will block every pull
request while it waits. Replace them with the single
`AWS CodeBuild craftcv-backend-ci` check.

---

## Phase 6 - Continuous deployment over SSM

```
merge to develop -> CodeBuild (gates + image) -> ssm:SendCommand
    -> craftcv-deploy document on i-… -> fetch/reset -> compose build
       -> migrate -> recreate web -> health check
```

No SSH, no key pair, port 22 closed. Every deploy is an SSM command, so it is
attributable in CloudTrail and its output is captured in the build log.

### Why a document and not a script on the box

The procedure lives in `scripts/ssm-deploy.sh`, wrapped by the
`craftcv-deploy` SSM document in `deploy.tf`. Two reasons over a script
maintained on the instance:

- What runs is version controlled and reviewed here, not edited in place over
  a shell session with no record of who changed it.
- The CodeBuild role can be granted `ssm:SendCommand` on **this document
  only**, rather than on `AWS-RunShellScript`. Scoping to the general shell
  document would let the build role run any command on the instance; scoping
  to this one lets it run exactly the reviewed deploy.

Document parameters are constrained by `allowedPattern`, so `CommitSha` must
look like a SHA before it ever reaches bash.

### What the deploy does

1. Takes the deployment lock (`flock` on `/var/lock/craftcv-deploy.lock`),
   waiting up to 600s. Two merges landing together queue rather than run
   `git reset` over each other. Exit code 75 means the lock was never free.
2. Rewrites the git remote to the canonical URL - idempotent, and it scrubs
   any credential a previous setup embedded there.
3. Fetches `origin/develop` and **refuses to continue unless the requested
   commit is an ancestor of it**, so the document cannot be used to pin the
   box to an arbitrary revision.
4. `git reset --hard` to that commit. Deliberately never `git clean`: `.env`
   is untracked and holds the database credentials.
5. `docker compose build web`, start `db`, wait for it to report healthy.
6. Migrations, then recreate `web`. In that order, so new code never serves
   traffic against an unmigrated schema.
7. Polls `http://127.0.0.1:8000/` for up to 60s. Any status below 500 counts
   as alive - a 404 on `/` is expected, since nothing is routed there.
8. Prunes superseded images. The instance has only a few GB free.

Any failure exits non-zero, and the build fails with it.

### When it deploys

The gate is in `buildspec.yml` and fails closed:

| Trigger | Deploys? |
| ------- | -------- |
| Pull request build, any branch | No - event is not `PUSH` |
| Push to a feature branch | No - wrong ref (and no webhook filter matches) |
| Push to `main` | No - only `develop` deploys |
| **Failed** build on `develop` | No - `CODEBUILD_BUILD_SUCCEEDING` is not 1 |
| **Successful** push to `develop` | **Yes** |
| Manual build of `develop` | Yes |
| Manual build of any other branch | No |

CodeBuild polls the command to completion rather than firing and forgetting,
so a green build means the deploy actually finished. The deploy's stdout and
stderr are echoed into the build log.

### Running a deploy by hand

```bash
aws ssm send-command --region eu-west-1   --document-name craftcv-deploy   --instance-ids "$(terraform output -raw instance_id)"   --parameters CommitSha=<full-sha-on-develop>
```

### GitHub credentials on the instance

CraftCV-backend is private, so the deploy's `git fetch` needs a token. The
instance reads the **same** Secrets Manager secret CodeBuild uses - one
credential, one place to rotate - and its role is scoped to that one secret.

The token is handed to git through a per-invocation credential helper, so it
never lands in `.git/config`, never appears in argv, and never touches disk.
This also means the AWS CLI must be present on the instance; it was installed
by hand during Phase 6 and should move into user data or the AMI before the
box is ever rebuilt, or the first deploy on a fresh instance will fail with
`aws CLI not installed on this instance`.

The repository was public earlier in this project and became private
mid-phase, which is exactly how this gap was found: a deploy failed with
`could not read Username for 'https://github.com'`. It failed before touching
the checkout, which is the behaviour to preserve in any change to the script.

### Known gap: the ECR image is not what runs

Phase 5 builds and pushes an image to ECR; Phase 6, as specified, does
`fetch/reset` and rebuilds on the instance. So the artifact CI tested is not
the artifact serving traffic - they are built from the same commit, but not
the same bytes. Closing that means pulling the image instead of rebuilding,
which needs the AWS CLI installed on the instance and an ECR-pull policy on
its role. Worth doing; out of scope for this phase.

---

## Sandbox schedule

The app server is a sandbox, so it does not need to run overnight or at the
weekend. Two EventBridge schedules power it on and off:

```
06:00 Africa/Accra  Mon-Fri    start  craftcv-app-server
18:00 Africa/Accra  every day  stop   craftcv-app-server
```

Twelve hours a weekday instead of twenty-four, and nothing across Saturday
and Sunday.

The asymmetry between the two is deliberate. The start is `MON-FRI`, so the
weekend stays off unless somebody turns it on. The stop runs every day, so
an instance started by hand on a Saturday is still stopped that evening
instead of running until Monday - the exact runaway the schedule exists to
prevent. A stop with nothing to stop is free and harmless.

To work at the weekend, start it by hand; the 18:00 stop will catch it that
same evening.

```
aws ec2 start-instances \
  --instance-ids "$(terraform output -raw instance_id)" \
  --region eu-west-1
```

Change `sandbox_start_hour`, `sandbox_stop_hour`, `sandbox_start_days`,
`sandbox_stop_days` or `sandbox_schedule_timezone`, or set
`sandbox_schedule_enabled = false` to suspend it entirely without destroying
anything.

The timezone is **Africa/Accra**, not the region's local time. The people
using this sandbox are in Ghana, and Accra has no daylight saving, so 06:00
stays 06:00 all year. Following `Europe/Dublin` instead would shift the
wall-clock times twice a year.

It is two schedules and one IAM role - no Lambda to write and patch, no
Instance Scheduler stack. EventBridge Scheduler calls `ec2:StartInstances`
and `ec2:StopInstances` directly through a universal target, and its role is
scoped to that one instance.

### Three consequences to expect

- **Deploys fail while it is off.** `ssm:SendCommand` to a stopped instance
  goes nowhere, so a merge to develop after 18:00, or at any point over the
  weekend, produces a red build. The build is correct to fail: nothing was
  deployed. Re-run it after the next 06:00 start, or start the instance by
  hand and re-run it then.
- **The containers come back on their own.** Both services are
  `restart: unless-stopped`, so Docker brings them up at boot with no
  intervention - including Monday morning, after the weekend off.
- **The address survives the stop.** An Elastic IP is associated with the
  instance (`eip.tf`), so it keeps the same public IP and the same
  `ec2-<dashed-ip>.eu-west-1.compute.amazonaws.com` hostname across every
  restart. Nothing pointing at it breaks on Monday.

---

## The frontend

CraftCV-frontend is a Nuxt app. nginx on the instance serves both halves
from one origin:

```
/        the generated Nuxt site, static files under /var/www/craftcv
/api/    Django, proxied to 127.0.0.1:8000
/admin/  Django admin, same proxy
```

One origin is the point. The browser only calls the host it loaded the page
from, so `runtimeConfig.public.apiBase` is the relative path `/api` and no
server address is baked into the bundle. That matters because the sandbox
restarts nightly on a new public IP, and a static build bakes its
configuration in at build time - a hardcoded address would need a rebuild,
not a restart, to fix. It also means the two halves need no CORS between
them.

### The instance does not build the frontend

CodeBuild generates the site, uploads it to
`s3://craftcv-frontend-artifacts-<account>/builds/<commit>/`, and the SSM
document syncs it down. The bucket is private; this is an artifact store, not
website hosting.

Building on the box cost 364MB of node_modules, an 84MB npm cache and a 137MB
Node runtime to serve 220KB of output, on a 7.6GB disk - and needed 1GB of
swap to survive a Nuxt build in 914MB of RAM. Syncing costs the 220KB.
Removing all of it reclaimed 800MB.

Permissions split by direction: the build may `PutObject` under `builds/*`
and cannot read or delete; the instance may `GetObject` and cannot write.

Publishing swaps the directory into place, so nobody sees a half-copied site,
and rolls back to the previous one if the new site fails its health check.

### Swap is still needed

1GB of swap remains on the instance. The **backend** still builds its Docker
image there and uses about 235MB of it. Removing the swap would start failing
backend deploys.

Swap and the nginx configuration were both applied by hand during this work.
They belong in user data or an AMI before the instance is ever rebuilt.
