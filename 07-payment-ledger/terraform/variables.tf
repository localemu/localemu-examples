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
  default = "le-pay"
}
