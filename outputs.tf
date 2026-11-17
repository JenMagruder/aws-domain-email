output "address" {
  value = local.address
}

output "smtp_server" {
  value = "email-smtp.${var.region}.amazonaws.com"
}

output "smtp_port" {
  value = 587
}

output "smtp_username" {
  value = var.create_smtp_user ? aws_iam_access_key.smtp[0].id : null
}

output "smtp_password" {
  value     = var.create_smtp_user ? aws_iam_access_key.smtp[0].ses_smtp_password_v4 : null
  sensitive = true
}