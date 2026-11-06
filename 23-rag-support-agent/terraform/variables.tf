variable "prefix" {
  type    = string
  default = "le-rag"
}

variable "llm_mode" {
  type    = string
  default = "local"
  validation {
    condition     = contains(["local", "bedrock"], var.llm_mode)
    error_message = "llm_mode must be 'local' or 'bedrock'."
  }
}

variable "opensearch_endpoint" {
  type        = string
  description = "Endpoint of the OpenSearch domain created by scripts/deploy.sh"
}
