#!/bin/bash
# Send an email through Gmail SMTP.
#
# Reads the body from a file argument, or from stdin if no file is given, e.g.:
#     analyze_reports.sh <build_dir> | send_report_email.sh
#     send_report_email.sh <build_dir>/analysis.txt
#
# Configuration (all via environment):
#   BOT_GMAIL_USER       Gmail address to send from (SMTP username).
#   BOT_GMAIL_PASSWORD   Gmail *app password* (not the normal account password;
#                        create one at https://myaccount.google.com/apppasswords).
#   BOT_RECIPIENT_EMAIL  Recipient address.
set -u

# Read the body first (from a file argument, else stdin) BEFORE checking config.
# This matters when we are the tail of a pipe like `analyze | tee f | send_email`:
# draining stdin lets `tee` flush completely even if we then bail on missing
# credentials, so the saved analysis file is never truncated.
if [ $# -ge 1 ] && [ -r "$1" ]; then
    body=$(cat "$1")
else
    body=$(cat)
fi

# Now require the credentials/recipient; exit cleanly (non-zero) if any is missing.
missing=
for v in BOT_GMAIL_USER BOT_GMAIL_PASSWORD BOT_RECIPIENT_EMAIL; do
    [ -n "${!v:-}" ] || missing="$missing $v"
done
if [ -n "$missing" ]; then
    echo "send_report_email.sh: not sending; unset:$missing" >&2
    exit 1
fi

# Derive a default subject from the report's Status / build lines if none supplied.
if [ -z "${REPORT_SUBJECT:-}" ]; then
    status=$(printf '%s\n' "$body" | sed -n 's/^Status: *//p' | head -1)
    build=$(printf '%s\n'  "$body" | sed -n 's/^Build: *//p'  | head -1 | awk '{print $1}')
    REPORT_SUBJECT="[OASIS${build:+ $build}] ${status:-report analysis}"
fi

BOT_GMAIL_USER="$BOT_GMAIL_USER" \
BOT_GMAIL_PASSWORD="$BOT_GMAIL_PASSWORD" \
BOT_RECIPIENT_EMAIL="$BOT_RECIPIENT_EMAIL" \
REPORT_SUBJECT="$REPORT_SUBJECT" \
REPORT_BODY="$body" \
python3 - <<'PY'
import os, smtplib, ssl, html
from email.message import EmailMessage

user      = os.environ["BOT_GMAIL_USER"]
password  = os.environ["BOT_GMAIL_PASSWORD"]
recipient = os.environ["BOT_RECIPIENT_EMAIL"]
subject   = os.environ["REPORT_SUBJECT"]
body      = os.environ["REPORT_BODY"]

msg = EmailMessage()
msg["From"]    = user
msg["To"]      = recipient
msg["Subject"] = subject
# The report is a column-aligned monospace table. Plain text alone renders in the
# client's proportional font and misaligns, so send a multipart message: a plain
# fallback plus an HTML part that forces a monospace font via <pre>.
msg.set_content(body)
html_body = (
    '<html><body>'
    '<pre style="font-family: \'DejaVu Sans Mono\',Consolas,Menlo,monospace; '
    'font-size: 12px; line-height: 1.25; white-space: pre;">'
    + html.escape(body) +
    '</pre></body></html>'
)
msg.add_alternative(html_body, subtype="html")

ctx = ssl.create_default_context()
with smtplib.SMTP_SSL("smtp.gmail.com", 465, context=ctx) as smtp:
    smtp.login(user, password)
    smtp.send_message(msg)

print(f"Emailed report to {recipient} (subject: {subject!r})")
PY
