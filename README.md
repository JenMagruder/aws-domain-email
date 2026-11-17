# aws-domain-email

Email at your own domain on AWS for about 50 cents a month. Mail comes in through Amazon SES and lands in your Gmail. You reply from Gmail and it goes out as your domain. Everything is Terraform.

Full walkthrough: [Build Your Own Custom Domain Email on AWS with Gmail](https://stratajen.net/blog/aws-domain-email.html)

## How it works

**Getting mail**

1. Your domain's MX record sends mail to SES.
2. An SES receipt rule matches your address and scans it for spam and viruses.
3. SES saves the raw email to S3, then runs a Lambda.
4. The Lambda rewrites From to your domain, keeps the real sender in Reply-To, and forwards it to Gmail.

**Sending mail**

1. Gmail "Send mail as" sends through the SES SMTP endpoint.
2. SES signs it with DKIM for your domain.
3. People see your domain address, not your Gmail.

## What this creates

| Piece | What it does |
| --- | --- |
| Route 53 records | MX, DKIM, SPF, and DMARC for your domain |
| SES identities | Your domain, plus your Gmail while you're in the sandbox |
| S3 bucket | Holds raw incoming mail, deleted after 90 days |
| Lambda | Forwards each email to Gmail |
| SES receipt rule | Sends mail for your address to S3, then the Lambda |
| IAM user | The SMTP login Gmail uses to send as your domain |

## Before you start

- An AWS account you can use from the AWS CLI with admin access
- A domain with a **public hosted zone in Route 53**, in that same account
- A Gmail account to forward to
- Terraform 1.10 or newer
- **A budget alert.** In the AWS console, search for Budgets, then Create budget, Use a template, Monthly cost budget. Set something like $10.

New to AWS? [AWS Skill Builder](https://skillbuilder.aws) has free training.

## Preflight checks

**No MX record yet.** If your domain already gets email somewhere, this would take it over.

```bash
dig MX YOUR_DOMAIN +short                      # Mac or Linux
Resolve-DnsName YOUR_DOMAIN -Type MX           # Windows PowerShell
```

Nothing back, or just an SOA line, means you're good.

**No active receipt rule set.** Only one can be active per region.

```bash
aws ses describe-active-receipt-rule-set --region YOUR_REGION
```

No output means you're good.

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars with your values

terraform init
terraform plan
terraform apply
```

Read the plan before you type `yes`. It should say **30 to add, 0 to change, 0 to destroy**.

## After you apply

1. **Verify your Gmail.** Click the link in the email from Amazon Web Services.
2. **Check that your domain verified.** Both should say `SUCCESS`. Give DNS up to an hour.
   ```bash
   aws sesv2 get-email-identity --email-identity YOUR_DOMAIN --region YOUR_REGION --query "{dkim:DkimAttributes.Status,mailfrom:MailFromAttributes.MailFromDomainStatus}"
   ```
3. **Send a test** to your new address from another account. It should show up in Gmail as "Their Name via YOUR_BRAND."
4. **Get your SMTP login.**
   ```bash
   terraform output smtp_username
   terraform output -raw smtp_password
   ```
5. **Set up Gmail "Send mail as."** Gmail settings, Accounts and Import, Add another email address.

   | Field | Value |
   | --- | --- |
   | SMTP Server | `email-smtp.YOUR_REGION.amazonaws.com` |
   | Port | `587`, TLS |
   | Username and password | From the outputs above |

6. **Request SES production access.** SES console, Account dashboard, Request production access. Until then you can only send to verified addresses.

## Never commit these

- `*.tfstate` holds your SMTP password in plain text
- `*.tfplan` can hold it too
- `terraform.tfvars` has your real domain and Gmail

The `.gitignore` already covers them. Run `git status` before your first push anyway.

**Never paste the SMTP password anywhere, including READMEs, commit messages, or screenshots.**

## Know before you build

- Sending takes two extra steps: connect Gmail, then get out of the SES sandbox.
- Gmail is your mailbox. No IMAP or webmail.
- You can't use it for "Sign in with Google."
- Every email shows "via YOUR_BRAND."
- Don't hit "Report spam" on forwarded mail. It counts against your own domain.
- Rotate the SMTP key every 90 days.
- Tighten DMARC to `p=quarantine` once your reports look clean.

## Cost

About $0.50 a month on free tier, mostly the Route 53 hosted zone. About $0.60 to $0.75 past free tier. If your domain is already in Route 53, this only adds pennies.

## Clean up

```bash
terraform destroy
```

Empty the inbound S3 bucket first if it has mail in it, or the destroy will fail on that bucket.