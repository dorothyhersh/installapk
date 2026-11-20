#!/usr/bin/env python3
"""Read the 5-digit Facebook confirmation code from YOUR Gmail inbox over IMAP.
Env: GMAIL_ADDRESS, GMAIL_APP_PASSWORD (Google "App password"), SINCE_EPOCH, CODE_WAIT (seconds)
Prints the code on stdout, exit 1 if none arrived.

Only accepts a code that is clearly labelled as the confirmation code:
  - subject "48090 is your Facebook confirmation code" (or "FB-48090")
  - body text right next to "confirmation code" / "FB-"
It never takes a random 5-digit number (postal code 94025 in the footer, etc.).
"""
import email, imaplib, os, re, sys, time
from email.header import decode_header, make_header
from email.utils import parsedate_to_datetime

user = os.environ["GMAIL_ADDRESS"]; pw = os.environ["GMAIL_APP_PASSWORD"].replace(" ", "")
since = float(os.environ.get("SINCE_EPOCH", time.time() - 600))
deadline = time.time() + int(os.environ.get("CODE_WAIT", "240"))
day = time.strftime("%d-%b-%Y", time.gmtime(since - 86400))

# numbers that appear in Facebook/Meta mail footers and are never the code
NOT_CODES = {"94025", "94026"}

SUBJECT_PATTERNS = [
    r"\b(\d{5})\s+is your (?:Facebook )?(?:confirmation )?code\b",
    r"\bFB-(\d{5})\b",
    r"\bconfirmation code[^0-9]{0,20}(\d{5})\b",
]
BODY_PATTERNS = [
    r"\bFB-(\d{5})\b",
    r"confirmation code[^0-9]{0,80}?(?<!\d)(\d{5})(?!\d)",
    r"(?<!\d)(\d{5})(?!\d)[^0-9]{0,40}is your (?:Facebook )?(?:confirmation )?code",
]


def valid(c):
    return c and c not in NOT_CODES


def code_from(msg):
    subj = str(make_header(decode_header(msg.get("Subject", ""))))
    for p in SUBJECT_PATTERNS:
        m = re.search(p, subj, re.I)
        if m and valid(m.group(1)):
            return m.group(1)
    # only look in the body when the subject at least talks about a code
    if not re.search(r"code|confirm", subj, re.I):
        return None
    for part in msg.walk():
        if part.get_content_type() in ("text/plain", "text/html"):
            raw = part.get_payload(decode=True) or b""
            text = raw.decode("utf-8", "ignore")
            text = re.sub(r"<(style|script)[^>]*>.*?</\1>", " ", text, flags=re.S | re.I)
            text = re.sub(r"<[^>]+>", " ", text)
            text = re.sub(r"&nbsp;|\s+", " ", text)
            for p in BODY_PATTERNS:
                m = re.search(p, text, re.I)
                if m and valid(m.group(1)):
                    return m.group(1)
    return None


def msg_time(msg):
    try:
        return parsedate_to_datetime(msg["Date"]).timestamp()
    except Exception:
        return None


while time.time() < deadline:
    try:
        M = imaplib.IMAP4_SSL("imap.gmail.com"); M.login(user, pw)
        found = []  # (timestamp, code)
        for box in ("INBOX", "[Gmail]/Spam"):
            if M.select(box, readonly=True)[0] != "OK":
                continue
            _, data = M.search(None, "FROM", "facebookmail.com", "SINCE", day)
            for i in data[0].split()[-10:]:
                msg = email.message_from_bytes(M.fetch(i, "(RFC822)")[1][0][1])
                ts = msg_time(msg)
                if ts is not None and ts < since - 60:
                    continue
                c = code_from(msg)
                if c:
                    found.append((ts or 0, c))
        M.logout()
        if found:
            found.sort()                 # newest message wins
            print(found[-1][1])
            sys.exit(0)
    except Exception as e:
        print(f"imap error: {e}", file=sys.stderr)
    time.sleep(8)
sys.exit(1)
