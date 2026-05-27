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
  default = "le-rotcheck"
}

variable "schedule_expression" {
  type    = string
  default = "rate(1 hour)"
}
