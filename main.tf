terraform {
  backend "remote" {
    organization = "samcday"

    workspaces {
      name = "meagerkube"
    }
  }

  required_providers {
    hcloud = {
      source = "hetznercloud/hcloud"
      version = "1.28.1"
    }
  }

  required_version = "~> 1.0.0"
}

variable "hcloud_token" {
  sensitive = true
}

provider "hcloud" {
  token = var.hcloud_token
}

resource "hcloud_firewall" "firewall" {
  name = "firewall"
  rule {
    direction = "in"
    protocol = "tcp"
    port = "6443"
    description = "kube-apiserver"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
  rule {
    direction = "in"
    protocol = "tcp"
    port = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}
