# Put your own values in terraform.tfvars (copy terraform.tfvars.example).
# That file is gitignored, so your domain and Gmail never end up on GitHub.

variable "region" {
  description = "SES region that supports receiving email, like us-east-1, us-west-2, or eu-west-1."
  type        = string
  default     = "us-east-1"
}

variable "domain" {
  description = "Your domain. It needs a public Route 53 hosted zone in this account."
  type        = string
}

variable "mailbox" {
  description = "The part before the @."
  type        = string
}

variable "forward_to" {
  description = "Where incoming mail gets forwarded, like your Gmail address."
  type        = string
}

variable "brand" {
  description = "Shows in Gmail as 'Sender via BRAND'."
  type        = string
  default     = "MyDomain"
}

variable "mail_from_subdomain" {
  description = "Custom MAIL FROM subdomain so bounces and SPF line up with your domain."
  type        = string
  default     = "mail"
}

variable "retention_days" {
  description = "How long raw incoming mail stays in S3."
  type        = number
  default     = 90
}

variable "create_smtp_user" {
  description = "Create SMTP credentials so Gmail can send as your address. Set false if an SCP blocks IAM users."
  type        = bool
  default     = true
}