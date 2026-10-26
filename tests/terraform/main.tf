terraform {
  required_version = ">= 1.11"

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }

  backend "local" {}
}

variable "value" {
  type = string

  validation {
    condition     = var.value != "broken"
    error_message = "value is broken, as broken.tfvars intends."
  }
}

resource "null_resource" "this" {
  triggers = {
    value = var.value
  }
}
