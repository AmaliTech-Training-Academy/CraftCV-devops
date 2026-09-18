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

  required_version = ">= 1.5.0"
}

# This tells the AWS provider which region to operate in.
# Every resource below will be created in eu-west-1 (Ireland) unless
# explicitly overridden.

provider "aws" {
  region = "eu-west-1"
}
