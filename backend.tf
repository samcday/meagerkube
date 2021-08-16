terraform {
  backend "remote" {
    organization = "samcday"

    workspaces {
      name = "meagerkube"
    }
  }
  
  required_version = "~> 1.0.0"
}
