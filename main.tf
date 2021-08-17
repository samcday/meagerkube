terraform {
  backend "remote" {
    organization = "samcday"

    workspaces {
      name = "meagerkube"
    }
  }

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "1.28.1"
    }
  }

  required_version = "~> 1.0.0"
}

variable "hcloud_token" {
  sensitive = true
}

variable "ssh_prv" {
  sensitive = true
}

variable "kubeadm_certificate_key" {
  sensitive = true
}

variable "kubeadm_token" {
  sensitive = true
}

provider "hcloud" {
  token = var.hcloud_token
}

resource "hcloud_firewall" "firewall" {
  name   = "firewall"
  labels = {}

  dynamic "rule" {
    for_each = { "22" : "ssh", "443" : "https", "6443" : "kube-apiserver" }
    content {
      direction   = "in"
      protocol    = "tcp"
      port        = rule.key
      description = rule.value
      source_ips  = ["0.0.0.0/0", "::/0"]
    }
  }
}

resource "hcloud_network" "network" {
  name     = "network"
  ip_range = "10.240.0.0/13"
  labels   = {}
}

resource "hcloud_network_subnet" "subnet-nodes" {
  network_id   = hcloud_network.network.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "10.240.0.0/16"
}

resource "hcloud_ssh_key" "sam" {
  name       = "sam"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFwawprQXEkGl38Q7T0PNseL0vpoyr4TbATMkEaZJTWQ"
}

resource "hcloud_ssh_key" "terraform" {
  name       = "terraform"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJLBm9E7KbYp/WF4HJdYzVhSOb/0YJVY9HyVtVghM+Ol"
}

resource "hcloud_load_balancer" "lb" {
  name               = "lb"
  load_balancer_type = "lb11"
  location           = "fsn1"
}

resource "hcloud_load_balancer_network" "lb-network" {
  load_balancer_id = hcloud_load_balancer.lb.id
  subnet_id        = hcloud_network_subnet.subnet-nodes.id
  ip               = "10.240.0.99"
}

resource "hcloud_server" "node" {
  count = 3

  name         = "node${count.index}"
  server_type  = "cx21"
  image        = "45559722"
  location     = "fsn1"
  firewall_ids = [hcloud_firewall.firewall.id]
  ssh_keys     = [hcloud_ssh_key.sam.id, hcloud_ssh_key.terraform.id]

  connection {
    host        = self.ipv4_address
    user        = "root"
    private_key = var.ssh_prv
  }

  provisioner "file" {
    content = templatefile("kubeadm.yaml", {
      kubeadm_cert_key = var.kubeadm_certificate_key,
      kubeadm_token    = var.kubeadm_token,
      lb_private_ip    = hcloud_load_balancer_network.lb-network.ip,
      lb_public_ip     = hcloud_load_balancer.lb.ipv4
      node_ip          = "10.240.0.${100 + count.index}",
    })
    destination = "/root/kubeadm.yaml"
  }
}

resource "hcloud_server_network" "node-privnet" {
  count = 3

  server_id = hcloud_server.node[count.index].id
  subnet_id = hcloud_network_subnet.subnet-nodes.id
  ip        = "10.240.0.${100 + count.index}"
}

resource "hcloud_load_balancer_target" "lb-target" {
  count = 3
  depends_on = [
    hcloud_load_balancer_network.lb-network,
    hcloud_server_network.node-privnet
  ]

  type             = "server"
  load_balancer_id = hcloud_load_balancer.lb.id
  server_id        = hcloud_server.node[count.index].id
  use_private_ip   = true
}

resource "hcloud_load_balancer_service" "load_balancer_service" {
  for_each         = toset(["443", "6443"])
  load_balancer_id = hcloud_load_balancer.lb.id
  protocol         = "tcp"
  listen_port      = each.value
  destination_port = each.value
}

resource "null_resource" "kubeadm-init" {
  triggers = {}

  connection {
    host        = hcloud_server.node[0].ipv4_address
    user        = "root"
    private_key = var.ssh_prv
  }

  provisioner "remote-exec" {
    inline = [
      "kubeadm init --config /root/kubeadm.yaml --upload-certs"
    ]
  }
}

resource "null_resource" "kubeadm-join" {
  count = 3
  depends_on = [
    # Can't join a cluster that doesn't exist yet, bruh.
    null_resource.kubeadm-init,
    # This makes sure that the node isn't disconnected from the private network before we've done a `kubeadm reset`.
    hcloud_server_network.node-privnet,
  ]

  triggers = {
    ssh_prv = var.ssh_prv
    # Ensures that provisioner reruns if a node is recreated.
    server_id = hcloud_server.node[count.index].id
    host      = hcloud_server.node[count.index].ipv4_address
  }

  connection {
    host        = self.triggers.host
    user        = "root"
    private_key = self.triggers.ssh_prv
  }

  provisioner "remote-exec" {
    inline = [
      "[ ! -f /etc/kubernetes/kubelet.conf ] && kubeadm join --config /root/kubeadm.yaml || true"
    ]
  }

  provisioner "remote-exec" {
    when   = destroy
    inline = ["kubeadm reset -f"]
  }
}
