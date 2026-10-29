# Infrastructure for publishing notes: one KV namespace holding rendered
# pages and one Worker serving them on workers.dev. libnote embeds this
# file and runs it; afterwards everything is a normal Cloudflare resource
# that can be changed from the dashboard.

terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

variable "account_id" {
  type = string
}

variable "name" {
  type    = string
  default = "folio"
}

# The token comes from CLOUDFLARE_API_TOKEN so it never lands in tfstate.
provider "cloudflare" {}

resource "cloudflare_workers_kv_namespace" "notes" {
  account_id = var.account_id
  title      = var.name
}

resource "cloudflare_workers_script" "notes" {
  account_id  = var.account_id
  script_name = var.name
  content     = file("${path.module}/worker.js")
  main_module = "worker.js"

  bindings = [{
    type         = "kv_namespace"
    name         = "NOTES"
    namespace_id = cloudflare_workers_kv_namespace.notes.id
  }]
}

resource "cloudflare_workers_script_subdomain" "notes" {
  account_id  = var.account_id
  script_name = cloudflare_workers_script.notes.script_name
  enabled     = true
}

output "namespace_id" {
  value = cloudflare_workers_kv_namespace.notes.id
}

output "script_name" {
  value = cloudflare_workers_script.notes.script_name
}
