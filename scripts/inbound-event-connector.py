#!/usr/bin/env python3
"""External runtime worker for durable inbound-event delivery."""
import hashlib
import hmac
import ipaddress
import json
import os
import re
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

STOP = False
REQUIRED = {"source", "external_id", "type", "conversation_id", "runtime_id", "message", "attributes"}
ATTRIBUTE_KEYS = {"team_id", "channel_id", "actor_id", "message_ts", "thread_ts"}
TIMESTAMP = re.compile(r"^\d{1,20}\.\d{1,6}$")
RUNTIME_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,190}$")
CONTROL_TIMEOUT = 15

def stop(signum, frame):
    global STOP
    STOP = True

def control(argv):
    try:
        return subprocess.run([os.path.join(os.path.dirname(__file__), "wp-control"), "coding-agents", "inbound", *argv], text=True, capture_output=True, timeout=CONTROL_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        return None

def valid_claim(value, runtime_id):
    if not isinstance(value, dict) or set(value) != {"id", "lease_token", "event"} or not isinstance(value["id"], int) or value["id"] <= 0 or not isinstance(value["lease_token"], str) or not value["lease_token"]:
        return False
    event = value["event"]
    if not isinstance(event, dict) or not REQUIRED <= set(event) or set(event) - REQUIRED - {"data"} or not all(isinstance(event[key], str) and event[key] and len(event[key]) <= 65535 for key in REQUIRED - {"attributes"}):
        return False
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", event["source"]) or len(event["external_id"]) > 191 or not RUNTIME_ID.fullmatch(event["runtime_id"]) or event["runtime_id"] != runtime_id:
        return False
    attributes = event["attributes"]
    return ("data" not in event or isinstance(event["data"], dict)) and isinstance(attributes, dict) and len(attributes) <= 8 and all(isinstance(k, str) and re.fullmatch(r"[a-z][a-z0-9_]{0,63}", k) and isinstance(v, str) and v and len(v) <= 191 for k, v in attributes.items()) and len(json.dumps(event, separators=(",", ":")).encode()) <= 65536

def slack_config():
    if os.environ.get("WP_CODING_AGENTS_INBOUND_SLACK_ENABLED") != "1":
        raise ValueError("Slack local delivery is not explicitly enabled")
    endpoint = os.environ.get("WP_CODING_AGENTS_INBOUND_SLACK_ENDPOINT", "http://127.0.0.1:4000/slack/events")
    parsed = urllib.parse.urlparse(endpoint)
    try:
        loopback = parsed.hostname is not None and ipaddress.ip_address(parsed.hostname).is_loopback and parsed.port is not None
    except ValueError:
        loopback = False
    if parsed.scheme not in {"http", "https"} or not loopback or parsed.username or parsed.password or parsed.fragment:
        raise ValueError("Slack endpoint must be an http(s) loopback URL")
    secret_name = os.environ.get("WP_CODING_AGENTS_INBOUND_SLACK_SIGNING_SECRET_ENV", "")
    if not re.fullmatch(r"[A-Z_][A-Z0-9_]*", secret_name or "") or not os.environ.get(secret_name):
        raise ValueError("Slack signing secret environment variable is not configured")
    return endpoint, os.environ[secret_name]

def deliver_slack(claim):
    event = claim["event"]
    attributes = event["attributes"]
    if event["source"] != "slack":
        raise ValueError("unsupported or malformed Slack event")
    endpoint, secret = slack_config()
    data = event.get("data", {})
    content_type = "application/json"
    if event["type"] in {"message", "app_mention"}:
        if set(attributes) != ATTRIBUTE_KEYS or not TIMESTAMP.fullmatch(attributes["message_ts"]) or not TIMESTAMP.fullmatch(attributes["thread_ts"]):
            raise ValueError("malformed Slack message")
        if set(data) - {"text", "files"} or not isinstance(data.get("text", event["message"]), str) or not isinstance(data.get("files", []), list) or len(data.get("files", [])) > 10:
            raise ValueError("malformed Slack content")
        message = {"type": event["type"], "user": attributes["actor_id"], "channel": attributes["channel_id"], "ts": attributes["message_ts"], "thread_ts": attributes["thread_ts"], "text": data.get("text", event["message"]), "files": data.get("files", [])}
        body = json.dumps({"type": "event_callback", "team_id": attributes["team_id"], "event_id": event["external_id"], "event": message}, separators=(",", ":")).encode()
    elif event["type"] == "command":
        if set(data) - {"team_id", "channel_id", "user_id", "user_name", "command", "text", "trigger_id"} or not all(isinstance(data.get(key), str) for key in {"team_id", "channel_id", "user_id", "command", "text", "trigger_id"}) or data["team_id"] != attributes.get("team_id") or data["user_id"] != attributes.get("actor_id") or data["channel_id"] != attributes.get("channel_id"):
            raise ValueError("malformed Slack command")
        endpoint = native_endpoint(endpoint, "commands")
        body = urllib.parse.urlencode(data).encode()
        content_type = "application/x-www-form-urlencoded"
    elif event["type"] in {"block_actions", "view_submission", "view_closed"}:
        if set(data) - {"type", "team", "user", "channel", "message", "trigger_id", "actions", "view"} or data.get("type") != event["type"] or not isinstance(data.get("team"), dict) or not isinstance(data.get("user"), dict) or data["team"].get("id") != attributes.get("team_id") or data["user"].get("id") != attributes.get("actor_id"):
            raise ValueError("malformed Slack control")
        if "channel" in data and (not isinstance(data["channel"], dict) or data["channel"].get("id") != attributes.get("channel_id")):
            raise ValueError("mismatched Slack control channel")
        endpoint = native_endpoint(endpoint, "interactions")
        body = urllib.parse.urlencode({"payload": json.dumps(data, separators=(",", ":"))}).encode()
        content_type = "application/x-www-form-urlencoded"
    else:
        raise ValueError("unsupported Slack event type")
    timestamp = str(int(time.time()))
    signature = "v0=" + hmac.new(secret.encode(), b"v0:" + timestamp.encode() + b":" + body, hashlib.sha256).hexdigest()
    request = urllib.request.Request(endpoint, body, {"Content-Type": content_type, "X-Slack-Request-Timestamp": timestamp, "X-Slack-Signature": signature}, method="POST")
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, request, fp, code, msg, headers, url):
            return None
    with urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect()).open(request, timeout=10) as response:
        if not 200 <= response.status < 300:
            raise RuntimeError("local delivery failed")

def native_endpoint(endpoint, route):
    parsed = urllib.parse.urlparse(endpoint)
    return urllib.parse.urlunparse(parsed._replace(path=parsed.path.rsplit("/", 1)[0] + "/" + route, query=""))

def retry(claim, delay):
    return control(["retry", str(claim["id"]), "--lease-token=" + claim["lease_token"], "--delay=" + str(delay)])

def main():
    once = "--once" in sys.argv[1:]
    runtime_id = os.environ.get("WP_CODING_AGENTS_RUNTIME_ID", "")
    if not RUNTIME_ID.fullmatch(runtime_id):
        return 1
    delay = 1
    while not STOP:
        result = control(["poll", "--format=json", "--runtime-id=" + runtime_id])
        try:
            poll = json.loads(result.stdout) if result is not None else None
        except json.JSONDecodeError:
            poll = None
        if result is None or result.returncode or not isinstance(poll, dict) or set(poll) - {"status", "claim"} or poll.get("status") not in {"empty", "claimed"}:
            time.sleep(delay)
            delay = min(delay * 2, 30)
            continue
        if poll["status"] == "empty":
            if once: return 0
            time.sleep(1)
            delay = 1
            continue
        claim = poll.get("claim")
        if not valid_claim(claim, runtime_id):
            if isinstance(claim, dict) and isinstance(claim.get("id"), int) and isinstance(claim.get("lease_token"), str): retry(claim, delay)
            if once: return 1
            time.sleep(delay); delay = min(delay * 2, 30); continue
        try:
            deliver_slack(claim)
            acknowledged = control(["ack", str(claim["id"]), "--lease-token=" + claim["lease_token"]])
            if acknowledged is None or acknowledged.returncode: raise RuntimeError("acknowledgement failed")
            delay = 1
        except (ValueError, RuntimeError, urllib.error.URLError, urllib.error.HTTPError, TimeoutError):
            retry(claim, delay)
            if once: return 1
            time.sleep(delay); delay = min(delay * 2, 30)
        if once: return 0
    return 0

if __name__ == "__main__":
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    raise SystemExit(main())
