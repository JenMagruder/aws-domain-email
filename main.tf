data "aws_caller_identity" "current" {}

data "aws_route53_zone" "this" {
  name         = var.domain
  private_zone = false
}

locals {
  account_id    = data.aws_caller_identity.current.account_id
  address       = "${var.mailbox}@${var.domain}"
  mail_from     = "${var.mail_from_subdomain}.${var.domain}"
  slug          = replace(var.domain, ".", "-")
  prefix        = "inbound/"
  rule_set_name = "${local.slug}-inbound"
  rule_name     = "forward-${var.mailbox}"

  # Built as a string so the bucket policy and Lambda permission
  # can reference the rule without a dependency loop.
  rule_arn = "arn:aws:ses:${var.region}:${local.account_id}:receipt-rule-set/${local.rule_set_name}:receipt-rule/${local.rule_name}"
}

# ---------------------------------------------------------------
# Domain identity, DKIM, MAIL FROM, DMARC
# ---------------------------------------------------------------

resource "aws_sesv2_email_identity" "domain" {
  email_identity = var.domain
}

resource "aws_route53_record" "dkim" {
  count   = 3
  zone_id = data.aws_route53_zone.this.zone_id
  name    = "${aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens[count.index]}._domainkey.${var.domain}"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens[count.index]}.dkim.amazonses.com"]
}

resource "aws_sesv2_email_identity_mail_from_attributes" "domain" {
  email_identity         = aws_sesv2_email_identity.domain.email_identity
  mail_from_domain       = local.mail_from
  behavior_on_mx_failure = "USE_DEFAULT_VALUE"
}

resource "aws_route53_record" "mail_from_mx" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = local.mail_from
  type    = "MX"
  ttl     = 600
  records = ["10 feedback-smtp.${var.region}.amazonses.com"]
}

resource "aws_route53_record" "mail_from_spf" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = local.mail_from
  type    = "TXT"
  ttl     = 600
  records = ["v=spf1 include:amazonses.com ~all"]
}

# Start at p=none, watch the reports for a couple weeks, then tighten.
resource "aws_route53_record" "dmarc" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = "_dmarc.${var.domain}"
  type    = "TXT"
  ttl     = 600
  records = ["v=DMARC1; p=none; rua=mailto:${local.address}; fo=1"]
}

# Fails on purpose if an MX already exists, so it never
# silently replaces mail routing you already have.
resource "aws_route53_record" "inbound_mx" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = var.domain
  type    = "MX"
  ttl     = 600
  records = ["10 inbound-smtp.${var.region}.amazonaws.com"]
}

# The sandbox only delivers to verified addresses.
# Applying this sends a verification email to forward_to.
resource "aws_sesv2_email_identity" "forward_to" {
  email_identity = var.forward_to
}

# ---------------------------------------------------------------
# Inbound storage
# ---------------------------------------------------------------

resource "aws_s3_bucket" "inbound" {
  bucket = "${local.slug}-inbound-mail-${local.account_id}"
}

resource "aws_s3_bucket_ownership_controls" "inbound" {
  bucket = aws_s3_bucket.inbound.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "inbound" {
  bucket                  = aws_s3_bucket.inbound.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "inbound" {
  bucket = aws_s3_bucket.inbound.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "inbound" {
  bucket = aws_s3_bucket.inbound.id
  rule {
    id     = "expire-inbound"
    status = "Enabled"
    filter {
      prefix = local.prefix
    }
    expiration {
      days = var.retention_days
    }
  }
}

data "aws_iam_policy_document" "inbound_bucket" {
  statement {
    sid       = "AllowSESPuts"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.inbound.arn}/${local.prefix}*"]

    principals {
      type        = "Service"
      identifiers = ["ses.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [local.rule_arn]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.inbound.arn, "${aws_s3_bucket.inbound.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "inbound" {
  bucket     = aws_s3_bucket.inbound.id
  policy     = data.aws_iam_policy_document.inbound_bucket.json
  depends_on = [aws_s3_bucket_public_access_block.inbound]
}

# ---------------------------------------------------------------
# Forwarder Lambda
# ---------------------------------------------------------------

data "archive_file" "forwarder" {
  type        = "zip"
  source_file = "${path.module}/lambda/forwarder.py"
  output_path = "${path.module}/build/forwarder.zip"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "forwarder" {
  name               = "${local.slug}-mail-forwarder"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "forwarder" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.forwarder.arn}:*"]
  }

  statement {
    sid       = "ReadInbound"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.inbound.arn}/${local.prefix}*"]
  }

  statement {
    sid     = "SendAsMailbox"
    actions = ["ses:SendRawEmail"]
    resources = [
      aws_sesv2_email_identity.domain.arn,
      aws_sesv2_email_identity.forward_to.arn,
    ]

    condition {
      test     = "StringEquals"
      variable = "ses:FromAddress"
      values   = [local.address]
    }
  }
}

resource "aws_iam_role_policy" "forwarder" {
  name   = "forwarder"
  role   = aws_iam_role.forwarder.id
  policy = data.aws_iam_policy_document.forwarder.json
}

resource "aws_cloudwatch_log_group" "forwarder" {
  name              = "/aws/lambda/${local.slug}-mail-forwarder"
  retention_in_days = 30
}

resource "aws_lambda_function" "forwarder" {
  function_name    = "${local.slug}-mail-forwarder"
  role             = aws_iam_role.forwarder.arn
  runtime          = "python3.13"
  handler          = "forwarder.handler"
  filename         = data.archive_file.forwarder.output_path
  source_code_hash = data.archive_file.forwarder.output_base64sha256
  timeout          = 30
  memory_size      = 256

  environment {
    variables = {
      BUCKET       = aws_s3_bucket.inbound.id
      PREFIX       = local.prefix
      FORWARD_FROM = local.address
      FORWARD_TO   = var.forward_to
      BRAND        = var.brand
    }
  }

  depends_on = [aws_cloudwatch_log_group.forwarder, aws_iam_role_policy.forwarder]
}

resource "aws_lambda_permission" "ses" {
  statement_id   = "AllowSESInvoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.forwarder.function_name
  principal      = "ses.amazonaws.com"
  source_account = local.account_id
  source_arn     = local.rule_arn
}

# ---------------------------------------------------------------
# Receipt rules
# Only one rule set can be active per account and region.
# ---------------------------------------------------------------

resource "aws_ses_receipt_rule_set" "main" {
  rule_set_name = local.rule_set_name
}

resource "aws_ses_active_receipt_rule_set" "main" {
  rule_set_name = aws_ses_receipt_rule_set.main.rule_set_name
}

resource "aws_ses_receipt_rule" "forward" {
  name          = local.rule_name
  rule_set_name = aws_ses_receipt_rule_set.main.rule_set_name
  recipients    = [local.address]
  enabled       = true
  scan_enabled  = true
  tls_policy    = "Optional"

  s3_action {
    bucket_name       = aws_s3_bucket.inbound.id
    object_key_prefix = local.prefix
    position          = 1
  }

  lambda_action {
    function_arn    = aws_lambda_function.forwarder.arn
    invocation_type = "Event"
    position        = 2
  }

  # SES test writes to the bucket and checks invoke rights
  # when it creates the rule, so both must exist first.
  depends_on = [aws_s3_bucket_policy.inbound, aws_lambda_permission.ses]
}

# ---------------------------------------------------------------
# SMTP credentials so Gmail can send as your address
# ---------------------------------------------------------------

resource "aws_iam_user" "smtp" {
  count = var.create_smtp_user ? 1 : 0
  name  = "ses-smtp-${var.mailbox}-${local.slug}"
}

data "aws_iam_policy_document" "smtp" {
  statement {
    actions   = ["ses:SendRawEmail"]
    resources = [aws_sesv2_email_identity.domain.arn]

    condition {
      test     = "StringEquals"
      variable = "ses:FromAddress"
      values   = [local.address]
    }
  }
}

resource "aws_iam_user_policy" "smtp" {
  count  = var.create_smtp_user ? 1 : 0
  name   = "send-as-${var.mailbox}"
  user   = aws_iam_user.smtp[0].name
  policy = data.aws_iam_policy_document.smtp.json
}

# The secret lands in state. Keep state private.
resource "aws_iam_access_key" "smtp" {
  count = var.create_smtp_user ? 1 : 0
  user  = aws_iam_user.smtp[0].name
}