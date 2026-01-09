from flask import Flask, request
import requests
import os
import base64

app = Flask(__name__)

NTFY_TOPIC = os.getenv("NTFY_TOPIC", "alerts")
NTFY_URL = os.getenv("NTFY_URL", "https://ntfy.sh")
NTFY_USER = os.getenv("NTFY_USER", "")
NTFY_PASS = os.getenv("NTFY_PASS", "")

def build_ntfy_payload(data):
    status = data.get("status", "").lower()
    common_labels = data.get("commonLabels", {})
    common_annotations = data.get("commonAnnotations", {})
    alerts = data.get("alerts", [])

    # Title
    if status == "firing":
        title = f"{common_labels.get('alertname', 'Alert')}"
    else:
        title = f"{common_labels.get('alertname', 'Alert')} Resolved"

    # Message body
    message_lines = []
    if status == "firing":
        message_lines.append("Status: FIRING")
        message_lines.append(f"Severity: {common_labels.get('severity', '').upper()}")
        if "summary" in common_annotations:
            message_lines.append(f"Summary: {common_annotations['summary']}")
        if "description" in common_annotations:
            message_lines.append(f"Description: {common_annotations['description']}")
    else:
        message_lines.append("Alert has been resolved.")

    instances = " ".join([a.get("labels", {}).get("instance", "") for a in alerts])
    message_lines.append(f"Instance(s): {instances.strip()}")

    body = "\n".join(message_lines)

    # Tags
    tags = "warning,skull" if status == "firing" else "green_circle"

    # Priority
    if status == "firing":
        severity = common_labels.get("severity", "")
        priority = {
            "critical": "5",
            "warning": "4"
        }.get(severity, "3")
    else:
        priority = "2"

    return title, body, tags, priority

@app.route("/", methods=["POST"])
def alert():
    data = request.json
    alerts = data.get("alerts", [])

    print(f"Alerts received: {len(alerts)}")
    results = []
    for alert_data in alerts:
        # Wrap single alert in the format build_ntfy_payload expects
        mini_data = {
            "status": data.get("status", ""),
            "commonLabels": alert_data.get("labels", {}),
            "commonAnnotations": alert_data.get("annotations", {}),
            "alerts": [alert_data],
        }

        title, message, tags, priority = build_ntfy_payload(mini_data)

        headers = {
            "Content-Type": "text/plain; charset=utf-8",
            "X-Title": title,
            "X-Tags": tags,
            "X-Priority": priority
        }

        if NTFY_USER and NTFY_PASS:
            credentials = f"{NTFY_USER}:{NTFY_PASS}"
            encoded = base64.b64encode(credentials.encode("utf-8")).decode("utf-8")
            headers["Authorization"] = f"Basic {encoded}"

        response = requests.post(
            f"{NTFY_URL.rstrip('/')}/{NTFY_TOPIC}",
            data=message.encode("utf-8"),
            headers=headers
        )
        print(response.status_code, response.text)

        results.append(response.status_code)

    return ("ok", 200) if all(code == 200 for code in results) else ("Failed", 500)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5001)
