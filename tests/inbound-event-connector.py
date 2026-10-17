#!/usr/bin/env python3
import hashlib
import hmac
import http.server
import json
import os
import shutil
import subprocess
import tempfile
import threading
from pathlib import Path

ROOT = Path(__file__).parents[1]
SECRET = "connector-test-secret"
WP_SECRET = "wordpress-connector-secret"
MESSAGE = "private event body"

class Receiver(http.server.BaseHTTPRequestHandler):
    requests = []
    status = 200
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        self.__class__.requests.append((self.headers, body))
        self.send_response(self.__class__.status)
        if self.__class__.status == 302:
            self.send_header("Location", "http://198.51.100.1/not-loopback")
        self.end_headers()
    def log_message(self, format, *args): pass

def claim(message_ts, thread_ts, event_type="message", actor="U123"):
    return {"id": 9, "lease_token": "lease-9", "event": {"source": "slack", "external_id": "event-" + message_ts, "type": event_type, "conversation_id": "C123:" + thread_ts, "runtime_id": "runtime", "message": MESSAGE, "attributes": {"team_id": "T123", "channel_id": "C123", "actor_id": actor, "message_ts": message_ts, "thread_ts": thread_ts}}}

def wp_claim(run_id, event_type="chat_message", attachments=None):
    event = {"source": "agents-chat", "external_id": "turn-" + run_id, "type": event_type, "conversation_id": "wpca-1", "runtime_id": "runtime", "message": MESSAGE, "attributes": {"agent": "franklin", "run_id": run_id, "actor_user_id": "7", "runtime_conversation_id": "rc-1", "claim_token": "tok-1"}}
    if attachments is not None:
        event["attachments"] = attachments
    return {"id": 11, "lease_token": "lease-11", "event": event}

with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    bindir = root / ".wp-coding-agents/bin"
    bindir.mkdir(parents=True)
    connector = bindir / "inbound-event-connector"
    shutil.copy(ROOT / "scripts/inbound-event-connector.py", connector)
    connector.chmod(0o755)
    state, log = root / "state.json", root / "calls.log"
    fake = bindir / "wp-control"
    fake.write_text("#!/usr/bin/env python3\nimport json,os,sys\ns=json.load(open(os.environ['STATE']))\nopen(os.environ['LOG'],'a').write(' '.join(sys.argv[1:])+'\\n')\nif 'poll' in sys.argv: print(json.dumps(s)); sys.exit(0)\nsys.exit(0)\n")
    fake.chmod(0o755)
    server = http.server.HTTPServer(("127.0.0.1", 0), Receiver)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = os.environ | {"STATE": str(state), "LOG": str(log), "HTTP_PROXY": "http://198.51.100.1:1", "HTTPS_PROXY": "http://198.51.100.1:1", "WP_CODING_AGENTS_RUNTIME_ID": "runtime", "WP_CODING_AGENTS_INBOUND_SLACK_ENABLED": "1", "WP_CODING_AGENTS_INBOUND_SLACK_ENDPOINT": f"http://127.0.0.1:{server.server_port}/hook", "WP_CODING_AGENTS_INBOUND_SLACK_SIGNING_SECRET_ENV": "TEST_SLACK_SECRET", "TEST_SLACK_SECRET": SECRET}
    outputs = []
    for event in (claim("1710000000.000001", "1710000000.000001"), claim("1710000001.000001", "1710000000.000001", "app_mention", "W123")):
        state.write_text(json.dumps({"status": "claimed", "claim": event}))
        result = subprocess.run([str(connector), "--once"], env=env, capture_output=True, text=True)
        outputs.append(result.stdout + result.stderr)
        assert result.returncode == 0
    for headers, body in Receiver.requests[:2]:
        expected = "v0=" + hmac.new(SECRET.encode(), b"v0:" + headers["X-Slack-Request-Timestamp"].encode() + b":" + body, hashlib.sha256).hexdigest()
        assert headers["Content-Type"] == "application/json" and headers["X-Slack-Signature"] == expected
    root_payload, reply_payload = (json.loads(body) for _, body in Receiver.requests[:2])
    assert root_payload["event"]["type"] == "message" and root_payload["event"]["ts"] == root_payload["event"]["thread_ts"]
    assert reply_payload["event"]["type"] == "app_mention" and reply_payload["event"]["ts"] != reply_payload["event"]["thread_ts"] and reply_payload["event"]["user"] == "W123"
    assert log.read_text().count(" ack 9 --lease-token=lease-9") == 2
    assert "poll --format=json --runtime-id=runtime" in log.read_text()
    state.write_text(json.dumps({"status": "empty"}))
    assert subprocess.run([str(connector), "--once"], env=env, capture_output=True).returncode == 0
    for status in (500, 302):
        Receiver.status = status
        state.write_text(json.dumps({"status": "claimed", "claim": claim("1710000002.000001", "1710000000.000001")}))
        result = subprocess.run([str(connector), "--once"], env=env, capture_output=True, text=True)
        outputs.append(result.stdout + result.stderr)
        assert result.returncode == 1 and "retry 9 --lease-token=lease-9" in log.read_text()
    Receiver.status = 200
    bad = claim("1710000003.000001", "1710000000.000001")
    del bad["event"]["attributes"]["actor_id"]
    state.write_text(json.dumps({"status": "claimed", "claim": bad}))
    result = subprocess.run([str(connector), "--once"], env=env, capture_output=True, text=True)
    outputs.append(result.stdout + result.stderr)
    assert result.returncode == 1
    mismatched = claim("1710000004.000001", "1710000000.000001")
    mismatched["event"]["runtime_id"] = "other-runtime"
    state.write_text(json.dumps({"status": "claimed", "claim": mismatched}))
    result = subprocess.run([str(connector), "--once"], env=env, capture_output=True, text=True)
    outputs.append(result.stdout + result.stderr)
    assert result.returncode == 1 and len(Receiver.requests) == 4
    attached = claim("1710000005.000001", "1710000000.000001")
    attached["event"]["attachments"] = [{"type": "image", "url": "https://example.com/a.png"}]
    state.write_text(json.dumps({"status": "claimed", "claim": attached}))
    result = subprocess.run([str(connector), "--once"], env=env, capture_output=True, text=True)
    outputs.append(result.stdout + result.stderr)
    assert result.returncode == 1 and len(Receiver.requests) == 4, "attachments must never reach the Slack reconstruction endpoint"
    malformed = claim("1710000006.000001", "1710000000.000001")
    malformed["event"]["attachments"] = "not-a-list"
    state.write_text(json.dumps({"status": "claimed", "claim": malformed}))
    result = subprocess.run([str(connector), "--once"], env=env, capture_output=True, text=True)
    outputs.append(result.stdout + result.stderr)
    assert result.returncode == 1 and len(Receiver.requests) == 4
    # WordPress chat events (#771) go whole (attachments and claim_token
    # included) to the Roadie wordpress-platform plugin's loopback ingress,
    # signed with the WordPress-surface secret.
    env_wp = env | {"WP_CODING_AGENTS_INBOUND_WORDPRESS_ENABLED": "1", "WP_CODING_AGENTS_INBOUND_WORDPRESS_ENDPOINT": f"http://127.0.0.1:{server.server_port}/wordpress/events", "WP_CODING_AGENTS_INBOUND_WORDPRESS_SIGNING_SECRET_ENV": "TEST_WP_SECRET", "TEST_WP_SECRET": WP_SECRET}
    state.write_text(json.dumps({"status": "claimed", "claim": wp_claim("run_1", attachments=[{"type": "image", "url": "https://example.com/a.png"}])}))
    result = subprocess.run([str(connector), "--once"], env=env_wp, capture_output=True, text=True)
    outputs.append(result.stdout + result.stderr)
    assert result.returncode == 0 and len(Receiver.requests) == 5
    wp_headers, wp_body = Receiver.requests[4]
    expected = "v0=" + hmac.new(WP_SECRET.encode(), b"v0:" + wp_headers["X-WpCodingAgents-Request-Timestamp"].encode() + b":" + wp_body, hashlib.sha256).hexdigest()
    assert wp_headers["X-WpCodingAgents-Signature"] == expected and wp_headers["Content-Type"] == "application/json"
    wp_payload = json.loads(wp_body)
    assert wp_payload["event"] == wp_claim("run_1", attachments=[{"type": "image", "url": "https://example.com/a.png"}])["event"]
    assert " ack 11 --lease-token=lease-11" in log.read_text()
    # A cancel rides the same path; a malformed event or a surface that was
    # never enabled is retried, never guessed at.
    state.write_text(json.dumps({"status": "claimed", "claim": wp_claim("run_1", event_type="chat_cancel")}))
    result = subprocess.run([str(connector), "--once"], env=env_wp, capture_output=True, text=True)
    outputs.append(result.stdout + result.stderr)
    assert result.returncode == 0 and len(Receiver.requests) == 6 and json.loads(Receiver.requests[5][1])["event"]["type"] == "chat_cancel"
    unsupported = wp_claim("run_1")
    unsupported["event"]["type"] = "chat_unknown"
    state.write_text(json.dumps({"status": "claimed", "claim": unsupported}))
    result = subprocess.run([str(connector), "--once"], env=env_wp, capture_output=True, text=True)
    outputs.append(result.stdout + result.stderr)
    assert result.returncode == 1 and len(Receiver.requests) == 6
    state.write_text(json.dumps({"status": "claimed", "claim": wp_claim("run_1")}))
    result = subprocess.run([str(connector), "--once"], env=env, capture_output=True, text=True)
    outputs.append(result.stdout + result.stderr)
    assert result.returncode == 1 and len(Receiver.requests) == 6, "WordPress delivery must be explicitly enabled"
    observed = connector.read_text() + log.read_text() + "".join(outputs)
    assert SECRET not in observed and WP_SECRET not in observed and MESSAGE not in observed
    server.shutdown()
print("OK: inbound event connector assertions passed")
