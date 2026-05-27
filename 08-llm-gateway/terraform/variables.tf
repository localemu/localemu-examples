variable "target" {
  description = "Where to deploy: 'local' (LocalEmu) or 'aws' (real AWS)."
  type        = string
  default     = "local"
  validation {
    condition     = contains(["local", "aws"], var.target)
    error_message = "target must be 'local' or 'aws'."
  }
}

variable "prefix" {
  description = "Prefix for all resource names."
  type        = string
  default     = "le-llmgw"
}

variable "llm_mode" {
  description = "Which LLMClient implementation the Lambdas use. 'local' (the default) reads canned answers from local_answers.jsonl. 'bedrock' calls real Bedrock."
  type        = string
  default     = "local"
  validation {
    condition     = contains(["local", "bedrock"], var.llm_mode)
    error_message = "llm_mode must be 'local' or 'bedrock'."
  }
}

variable "sample_rate" {
  description = "Judge sampling rate (1.0 evaluates every response; drop in production)."
  type        = string
  default     = "1.0"
}
