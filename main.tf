terraform {
  backend "local" {}

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "1.28.1"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 0.5"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "3.1.0"
    }
  }

  required_version = "~> 1.0.0"
}

data "sops_file" "secrets" {
  source_file = "secrets.yaml"
}

variable "num_nodes" {
  default = 3
}

resource "tls_private_key" "key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "hcloud_firewall" "firewall" {
  name = "firewall"

  dynamic "rule" {
    for_each = { "22" : "ssh", "443" : "https" }
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
  public_key = tls_private_key.key.public_key_openssh
}

resource "hcloud_load_balancer" "lb" {
  name               = "lb"
  load_balancer_type = "lb11"
  location           = "fsn1"
}

resource "hcloud_load_balancer_network" "lb-network" {
  load_balancer_id = hcloud_load_balancer.lb.id
  subnet_id        = hcloud_network_subnet.subnet-nodes.id
}

resource "hcloud_server" "node" {
  count = var.num_nodes

  name         = "node${count.index}"
  server_type  = "cx21"
  image        = "debian-11"
  location     = "fsn1"
  firewall_ids = [hcloud_firewall.firewall.id]
  ssh_keys     = [hcloud_ssh_key.sam.id, hcloud_ssh_key.terraform.id]
  user_data    = <<-USERDATA
    #!/bin/bash
    set -uex -o pipefail

    # Adapted from `curl -fsSL https://get.docker.com | DRY_RUN=1 sh`

    apt-get update -qq >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq apt-transport-https ca-certificates curl gnupg

    curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
    curl -fsSL "https://download.docker.com/linux/debian/gpg" | gpg --dearmor --yes -o /usr/share/keyrings/docker-archive-keyring.gpg

    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list

    apt-get update -qq >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io kubelet=1.21.3-00 kubeadm=1.21.3-00 kubectl=1.21.3-00
    apt-mark hold kubelet kubeadm kubectl

    cat > /etc/docker/daemon.json <<EOF
    {
      "exec-opts": ["native.cgroupdriver=systemd"],
      "log-driver": "json-file",
      "log-opts": {
        "max-size": "100m"
      },
      "storage-driver": "overlay2"
    }
    EOF
    mkdir -p /etc/systemd/system/docker.service.d
    systemctl daemon-reload
    systemctl restart docker
  USERDATA
}

resource "hcloud_server_network" "node-privnet" {
  count = var.num_nodes

  server_id = hcloud_server.node[count.index].id
  subnet_id = hcloud_network_subnet.subnet-nodes.id
}

resource "hcloud_load_balancer_target" "lb-target" {
  count = var.num_nodes
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
  for_each = {
    "80" : "32080",
    "443" : "32443",
    "6443" : "6443",
  }
  load_balancer_id = hcloud_load_balancer.lb.id
  protocol         = "tcp"
  listen_port      = each.key
  destination_port = each.value
}

resource "null_resource" "kubeadm-init" {
  triggers = {}

  connection {
    host        = hcloud_server.node[0].ipv4_address
    user        = "root"
    private_key = tls_private_key.key.private_key_pem
  }

  provisioner "file" {
    content = templatefile("kubeadm.yaml", {
      kubeadm_cert_key = data.sops_file.secrets.data["kubeadm.cert_key"],
      kubeadm_token    = data.sops_file.secrets.data["kubeadm.token"],
      lb_private_ip    = hcloud_load_balancer_network.lb-network.ip,
      lb_public_ip     = hcloud_load_balancer.lb.ipv4
      node_ip          = hcloud_server_network.node-privnet[0].ip
    })
    destination = "/root/kubeadm.yaml"
  }

  provisioner "file" {
    source      = "flannel"
    destination = "/root"
  }

  provisioner "remote-exec" {
    inline = [
      "cloud-init status -w >/dev/null",
      "kubeadm init --config /root/kubeadm.yaml --upload-certs",
    ]
  }
}

resource "null_resource" "bootstrap-manifests" {
  for_each = toset(["flannel", "hcloud-ccm", "kubelet-rubber-stamp"])

  triggers = {
    init_id = null_resource.kubeadm-init.id,
  }

  connection {
    host        = hcloud_server.node[0].ipv4_address
    user        = "root"
    private_key = tls_private_key.key.private_key_pem
  }

  provisioner "file" {
    source      = each.value
    destination = "/root"
  }

  provisioner "remote-exec" {
    inline = [
      "KUBECONFIG=/etc/kubernetes/admin.conf kubectl apply -k ${each.value}",
    ]
  }
}

resource "null_resource" "sops-age-key" {
  triggers = {
    init_id      = null_resource.kubeadm-init.id,
    sops_age_key = data.sops_file.secrets.data["age_key"],
  }

  connection {
    host        = hcloud_server.node[0].ipv4_address
    user        = "root"
    private_key = tls_private_key.key.private_key_pem
  }

  provisioner "remote-exec" {
    inline = [
      "KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system create secret generic sops-age --from-literal=age.agekey=${self.triggers.sops_age_key}",
    ]
  }
}

resource "null_resource" "hcloud-token" {
  triggers = {
    init_id      = null_resource.kubeadm-init.id,
    hcloud_token = data.sops_file.secrets.data["hcloud_token"],
  }

  connection {
    host        = hcloud_server.node[0].ipv4_address
    user        = "root"
    private_key = tls_private_key.key.private_key_pem
  }

  provisioner "remote-exec" {
    inline = [
      "KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system create secret generic hcloud --from-literal=token=${self.triggers.hcloud_token}",
    ]
  }
}

resource "null_resource" "kubeadm-join" {
  count = var.num_nodes
  depends_on = [
    # This makes sure that the node isn't disconnected from the private network before we've done a `kubeadm reset`.
    hcloud_server_network.node-privnet,
  ]

  triggers = {
    # If kubeadm-init is tainted, then all nodes will be forced to recreate. This effectively resets the entire cluster state
    # without having to recreate the nodes.
    init_id = null_resource.kubeadm-init.id
    ssh_prv = tls_private_key.key.private_key_pem
    # Ensures that provisioner reruns if a node is recreated.
    server_id       = hcloud_server.node[count.index].id
    node_public_ip  = hcloud_server.node[count.index].ipv4_address
    node_private_ip = hcloud_server_network.node-privnet[count.index].ip
  }

  provisioner "file" {
    content = templatefile("kubeadm.yaml", {
      kubeadm_cert_key = data.sops_file.secrets.data["kubeadm.cert_key"],
      kubeadm_token    = data.sops_file.secrets.data["kubeadm.token"],
      lb_private_ip    = hcloud_load_balancer_network.lb-network.ip,
      lb_public_ip     = hcloud_load_balancer.lb.ipv4
      node_ip          = self.triggers.node_private_ip
    })
    destination = "/root/kubeadm.yaml"
  }

  connection {
    host        = self.triggers.node_public_ip
    user        = "root"
    private_key = self.triggers.ssh_prv
  }

  provisioner "remote-exec" {
    inline = [
      "[ -f /etc/kubernetes/kubelet.conf ] && true || { cloud-init status -w >/dev/null; kubeadm join --config /root/kubeadm.yaml; }"
    ]
  }

  provisioner "remote-exec" {
    when   = destroy
    inline = ["kubeadm reset -f"]
  }
}
