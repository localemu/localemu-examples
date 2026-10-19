variable "target" {
  type    = string
  default = "local"
  validation {
    condition     = contains(["local", "aws"], var.target)
    error_message = "target must be 'local' or 'aws'."
  }
}

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
