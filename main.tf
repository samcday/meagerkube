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
  labels = {}

  dynamic "rule" {
    for_each = {"22": "ssh", "443": "https", "6443": "kube-apiserver"}
    content {
      direction = "in"
      protocol = "tcp"
      port = rule.key
      description = rule.value
      source_ips = ["0.0.0.0/0", "::/0"]
    }
  }
}

resource "hcloud_network" "network" {
  name = "network"
  ip_range = "10.240.0.0/13"
}

resource "hcloud_network_subnet" "subnet-nodes" {
  network_id = hcloud_network.network.id
  type = "cloud"
  network_zone = "eu-central"
  ip_range = "10.240.0.0/16"
}
