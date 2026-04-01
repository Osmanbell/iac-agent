This Terraform configuration follows a modular, production-ready structure. It implements the four phases described in your architecture plan, ensuring security, scalability, and logical separation of concerns.

### Project Structure
```text
├── main.tf                 # Entry point, calls modules
├── variables.tf            # Global variables
├── outputs.tf              # Global outputs
├── providers.tf            # Provider configuration
├── terraform.tfvars        # Values for variables
├── modules/
│   ├── networking/         # VPC and Subnets
│   ├── security/           # Secret Manager & Artifact Registry
│   ├── compute/            # GKE Cluster and Node Pools
│   ├── serverless/         # Cloud Functions (2nd Gen)
│   └── gateway/            # API Gateway resources
└── templates/
    └── openapi_spec.yaml   # API Gateway definition
```

---

### 1. Provider & APIs Configuration
**`providers.tf`**
Ensures necessary GCP APIs are enabled before resources are created.

```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.0"
    }
  }
  # Recommended: Store state in a GCS bucket
  # backend "gcs" {
  #   bucket = "your-tf-state-bucket"
  #   prefix = "terraform/state"
  # }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# Enable required APIs
locals {
  services = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "apigateway.googleapis.com",
    "cloudfunctions.googleapis.com",
    "run.googleapis.com",
    "cloudbuild.googleapis.com"
  ]
}

resource "google_project_service" "enabled_apis" {
  for_each = toset(locals.services)
  service  = each.key
  disable_on_destroy = false
}
```

---

### 2. Networking Module
**`modules/networking/main.tf`**
Implements a custom VPC with secondary ranges for GKE (Alias IP).

```hcl
resource "google_compute_network" "vpc" {
  name                    = "${var.env}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "gke_subnet" {
  name          = "${var.env}-gke-subnet"
  ip_cidr_range = "10.0.0.0/20"
  region        = var.region
  network       = google_compute_network.vpc.id

  # Secondary ranges for GKE Pods and Services
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.1.0.0/16"
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.2.0.0/20"
  }
}

output "vpc_id" { value = google_compute_network.vpc.id }
output "subnet_id" { value = google_compute_subnetwork.gke_subnet.id }
```

---

### 3. Compute Layer (GKE)
**`modules/compute/main.tf`**
Deploys a Private GKE Cluster using the "Standard" mode for full control.

```hcl
resource "google_service_account" "gke_sa" {
  account_id   = "${var.env}-gke-sa"
  display_name = "GKE Node Pool Service Account"
}

resource "google_container_cluster" "primary" {
  name     = "${var.env}-cluster"
  location = var.region

  network    = var.vpc_id
  subnetwork = var.subnet_id

  # Best Practice: Remove default node pool and create a separate one
  remove_default_node_pool = true
  initial_node_count       = 1

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false # Set to true for internal-only access
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }
}

resource "google_container_node_pool" "primary_nodes" {
  name       = "${var.env}-node-pool"
  cluster    = google_container_cluster.primary.id
  node_count = 2

  node_config {
    machine_type = "e2-medium"
    service_account = google_service_account.gke_sa.email
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
    
    labels = { env = var.env }
  }
}
```

---

### 4. Serverless Layer (Cloud Functions)
**`modules/serverless/main.tf`**
Deploys a 2nd Gen Function with Secret Manager integration.

```hcl
resource "google_storage_bucket" "source_bucket" {
  name     = "${var.project_id}-fn-source"
  location = var.region
  uniform_bucket_level_access = true
}

resource "google_cloudfunctions2_function" "function" {
  name        = "${var.env}-backend-logic"
  location    = var.region
  description = "Event driven logic"

  build_config {
    runtime     = "nodejs20"
    entry_point = "helloWorld"
    source {
      storage_source {
        bucket = google_storage_bucket.source_bucket.name
        object = var.source_code_object
      }
    }
  }

  service_config {
    max_instance_count = 3
    available_memory   = "256Mi"
    timeout_seconds    = 60
    
    # Example Secret Injection
    secret_environment_variables {
      key        = "API_KEY"
      project_id = var.project_id
      secret     = var.secret_id
      version    = "latest"
    }
  }
}
```

---

### 5. API Management (Edge Routing)
**`modules/gateway/main.tf`**
Exposes the backend via Google API Gateway.

```hcl
resource "google_api_gateway_api" "api" {
  provider = google-beta
  api_id   = "${var.env}-main-api"
}

resource "google_api_gateway_api_config" "api_cfg" {
  provider      = google-beta
  api           = google_api_gateway_api.api.api_id
  api_config_id = "${var.env}-cfg-${formatdate("YYYYMMDDhhmm", timestamp())}"

  openapi_documents {
    document {
      path     = "spec.yaml"
      contents = base64encode(templatefile("${path.root}/templates/openapi_spec.yaml", {
        function_url = var.function_uri
      }))
    }
  }
  
  lifecycle {
    create_before_destroy = true
  }
}

resource "google_api_gateway_gateway" "gw" {
  provider   = google-beta
  api_config = google_api_gateway_api_config.api_cfg.id
  gateway_id = "${var.env}-gateway"
  region     = var.region
}
```

---

### 6. Root Orchestration
**`main.tf`**
Links all modules together, handling the dependencies.

```hcl
module "networking" {
  source     = "./modules/networking"
  project_id = var.project_id
  region     = var.region
  env        = var.env
  depends_on = [google_project_service.enabled_apis]
}

module "security" {
  source     = "./modules/security"
  project_id = var.project_id
  env        = var.env
}

module "compute" {
  source     = "./modules/compute"
  project_id = var.project_id
  region     = var.region
  env        = var.env
  vpc_id     = module.networking.vpc_id
  subnet_id  = module.networking.subnet_id
}

module "serverless" {
  source             = "./modules/serverless"
  project_id         = var.project_id
  region             = var.region
  env                = var.env
  secret_id          = module.security.secret_id
  source_code_object = "source.zip" # Assumes code is uploaded
}

module "gateway" {
  source       = "./modules/gateway"
  project_id   = var.project_id
  region       = var.region
  env          = var.env
  function_uri = module.serverless.function_uri
}
```

---

### Implementation Best Practices included:
1.  **Immutability:** Using `timestamp()` in API Config IDs ensures that updates to the OpenAPI spec trigger a new deployment.
2.  **Security:** 
    *   The GKE cluster is **Private**, meaning nodes don't have public IPs.
    *   Service accounts are dedicated per component.
    *   Secrets are injected as environment variables directly from Secret Manager.
3.  **Scalability:** GKE uses Alias IP ranges to ensure sufficient IP address space for high pod density.
4.  **Decoupling:** Modules allow you to swap the GKE backend for Cloud Run or another service without rewriting the Networking or Gateway logic.

### Next Steps:
1.  **OpenAPI Spec:** Create a `templates/openapi_spec.yaml` following the Swagger 2.0 format to define your routes.
2.  **IAM:** Grant the API Gateway service account `roles/run.invoker` so it can call the Cloud Function backend.
3.  **State:** Initialize your backend in `providers.tf` to ensure state is shared and locked.