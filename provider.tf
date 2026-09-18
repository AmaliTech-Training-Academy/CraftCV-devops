# This block tells Terraform which "provider" (cloud) plugin to download,
# and pins a version range so your infrastructure doesn't silently change
# behavior when a new provider version is released.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # 1.10 is the floor for use_lockfile below.
  required_version = ">= 1.10.0"

  # Remote state. Previously this was a terraform.tfstate file committed to
  # the repository, which meant the state could not be locked, went stale the
  # moment anyone applied, and put a file that can contain secrets into git
  # history.
  #
  # The bucket is created outside Terraform, by the commands recorded in the
  # README. It has to exist before Terraform can store its state in it, and
  # managing it from the state it holds would make the config impossible to
  # destroy cleanly.
  backend "s3" {
    bucket = "craftcv-tfstate-897729111286"
    key    = "craftcv-devops/terraform.tfstate"
    region = "eu-west-1"

    encrypt = true

    # S3-native locking (conditional writes). This replaces the DynamoDB
    # lock table the older docs describe - one less resource to run and pay
    # for, and DynamoDB locking is now deprecated.
    use_lockfile = true
  }
}

# This tells the AWS provider which region to operate in.
# Every resource below will be created in eu-west-1 (Ireland) unless
# explicitly overridden.

provider "aws" {
  region = "eu-west-1"
}
