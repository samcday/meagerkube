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
  labels = {}
}

resource "hcloud_network_subnet" "subnet-nodes" {
  network_id = hcloud_network.network.id
  type = "cloud"
  network_zone = "eu-central"
  ip_range = "10.240.0.0/16"
}

resource "hcloud_server" "node" {
  count = 3

  name = "node${count.index}"
  server_type = "cx21"
  image = "45559722"
  location = "fsn1"
  firewall_ids = [ hcloud_firewall.firewall.id ]

  network {
    network_id = hcloud_network.network.id
  }

  depends_on = [
    hcloud_network_subnet.subnet-nodes
  ]
}

resource "hcloud_load_balancer" "lb" {
  name = "lb"
  load_balancer_type = "lb11"
  location = "fsn1"
}

resource "hcloud_load_balancer_network" "lb-network" {
  load_balancer_id = hcloud_load_balancer.lb.id
  subnet_id = hcloud_network_subnet.subnet-nodes.id
}

resource "hcloud_load_balancer_target" "lb-target" {
  count = 3

  type = "server"
  load_balancer_id = hcloud_load_balancer.lb.id
  server_id = hcloud_server.node[count.index].id
  use_private_ip = true

  depends_on = [
    hcloud_load_balancer_network.lb-network
  ]
}

resource "hcloud_load_balancer_service" "load_balancer_service" {
  for_each = toset(["443", "6443"])
  load_balancer_id = hcloud_load_balancer.lb.id
  protocol = "tcp"
  listen_port = each.value
  destination_port = each.value
}
