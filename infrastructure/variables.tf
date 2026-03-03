variable "location" {
  description = "Azure Region for all resources"
  type        = string
  default     = "westus3" # Close to Vancouver, BC
}

variable "project_name" {
  description = "Base name for the project resources"
  type        = string
  default     = "yvrweather"
}

variable "environment" {
  description = "Environment name (e.g. dev, prod)"
  type        = string
  default     = "dev"
}
