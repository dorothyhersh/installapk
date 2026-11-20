#!/usr/bin/env python3
"""Read the 5-digit Facebook confirmation code from YOUR Gmail inbox over IMAP.
Env: GMAIL_ADDRESS, GMAIL_APP_PASSWORD (Google "App password"), SINCE_EPOCH, CODE_WAIT (seconds)
Prints the code on stdout, exit 1 if none arrived."""
import email, imaplib, os, re, sys, time
from email.header import decode_header, make_header
from email.utils import parsedate_to_datetime

user = os.environ["GMAIL_ADDRESS"]; pw = os.environ["GMAIL_APP_PASSWORD"].replace(" ", "")
since = float(os.environ.get("SINCE_EPOCH", time.time() - 600))
deadline = time.time() + int(os.environ.get("CODE_WAIT", "240"))
day = time.strftime("%d-%b-%Y", time.gmtime(since - 86400))

def code_from(msg):
    subj = str(make_header(decode_header(msg.get("Subject", ""))))
    m = re.search(r"\b(?:FB-)?(\d{5})\b", subj)
    if m: return m.group(1)
    for part in msg.walk():
        if part.get_content_type() in ("text/plain", "text/html"):
            body = part.get_payload(decode=True) or b""
            m = re.search(r"\b(\d{5})\b", re.sub(r"<[^>]+>", " ", body.decode("utf-8", "ignore")))
            if m: return m.group(1)
    return None

while time.time() < deadline:
    try:
        M = imaplib.IMAP4_SSL("imap.gmail.com"); M.login(user, pw)
        for box in ("INBOX", "[Gmail]/Spam"):
            if M.select(box, readonly=True)[0] != "OK": continue
            _, data = M.search(None, "FROM", "facebookmail.com", "SINCE", day)
            for i in reversed(data[0].split()[-10:]):
                msg = email.message_from_bytes(M.fetch(i, "(RFC822)")[1][0][1])
                try:
                    if parsedate_to_datetime(msg["Date"]).timestamp() < since - 60: continue
                except Exception: pass
                c = code_from(msg)
                if c: print(c); sys.exit(0)
        M.logout()
    except Exception as e:
        print(f"imap error: {e}", file=sys.stderr)
    time.sleep(8)
sys.exit(1)
