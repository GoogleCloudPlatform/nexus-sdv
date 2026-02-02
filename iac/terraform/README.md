# Terraform
## Start locally
Run through the following steps to run terraform locally. The default values of the variables will set the project id to `sdv-sandbox`.
```bash
# Authenticate against the GCP
gcloud auth application-default login
```
```bash
# You need to run this initially. 
terraform init -backend-config="bucket=sdv-sandbox-tfstate"
```
```bash
# Terraform creates a deployment plan for the current infrastructure
terraform plan
```
```bash
# Terraform plans the deployment and applies the changes after a review 
terraform apply
```