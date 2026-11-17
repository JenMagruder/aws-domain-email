"""Forward mail received by SES to a personal inbox.

SES writes the raw message to S3, then invokes this function. We pull the
message, rewrite the From header to the verified address (SES will not send
as someone else's domain), keep the original sender in Reply-To so hitting
reply still goes to them, and send it on.
"""

import email
import logging
import os
from email.utils import formataddr, parseaddr

import boto3

log = logging.getLogger()
log.setLevel(logging.INFO)

s3 = boto3.client("s3")
ses = boto3.client("ses")

BUCKET = os.environ["BUCKET"]
PREFIX = os.environ["PREFIX"]
FORWARD_FROM = os.environ["FORWARD_FROM"]
FORWARD_TO = os.environ["FORWARD_TO"]
BRAND = os.environ.get("BRAND", "forwarded")

# Headers that break or confuse resending: old signatures, SES managed
# headers, and the ones we replace.
STRIP_HEADERS = (
    "DKIM-Signature",
    "Return-Path",
    "Sender",
    "Message-ID",
    "From",
    "Reply-To",
)


def handler(event, context):
    record = event["Records"][0]["ses"]
    mail = record["mail"]
    receipt = record["receipt"]
    message_id = mail["messageId"]

    if receipt.get("virusVerdict", {}).get("status") == "FAIL":
        log.warning("Dropping %s: virus verdict FAIL", message_id)
        return {"status": "dropped_virus"}

    raw = s3.get_object(Bucket=BUCKET, Key=f"{PREFIX}{message_id}")["Body"].read()
    msg = email.message_from_bytes(raw)

    orig_from = msg.get("From", "")
    reply_to = msg.get("Reply-To") or orig_from
    name, addr = parseaddr(orig_from)
    label = name or addr or "Unknown sender"

    for header in STRIP_HEADERS:
        del msg[header]

    msg["From"] = formataddr((f"{label} via {BRAND}", FORWARD_FROM))
    if reply_to:
        msg["Reply-To"] = reply_to

    if receipt.get("spamVerdict", {}).get("status") == "FAIL":
        subject = msg.get("Subject", "")
        del msg["Subject"]
        msg["Subject"] = f"[SPAM?] {subject}"

    resp = ses.send_raw_email(
        Source=FORWARD_FROM,
        Destinations=[FORWARD_TO],
        RawMessage={"Data": msg.as_bytes()},
    )
    log.info("Forwarded %s as %s", message_id, resp["MessageId"])
    return {"status": "forwarded", "ses_message_id": resp["MessageId"]}
