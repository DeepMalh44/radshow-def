variable "name" {
  description = "Name of the resource group"
  type        = string
}

variable "location" {
  description = "Azure region for the resource group"
  type        = string
}

variable "tags" {
  description = "Tags to apply to the resource group"
  type        = map(string)
  default     = {}
}

variable "enable_delete_lock" {
  description = "Enable CanNotDelete lock on the resource group (recommended for PRD per IR-02)"
  type        = bool
  default     = false
}
