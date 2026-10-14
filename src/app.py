import json
import os
from aws_xray_sdk.core import patch_all

patch_all()
ENVIRONMENT = os.getenv("ENVIRONMENT", "unknown")


def handler(event, context):
    """Handler para Lambda directa, HTTP API y ALB."""
    path = _extract_path(event)
    method = _extract_method(event)
    if path == "/hello" and method in ("GET", "POST"):
        return _response(200, {"message": "hello", "environment": ENVIRONMENT,
                               "path": path, "method": method})
    return _response(404, {"message": "not found"})


def _extract_path(event):
    return event.get("rawPath", event.get("path", ""))


def _extract_method(event):
    http = event.get("requestContext", {}).get("http", {})
    return event.get("httpMethod") or http.get("method", "")


def _response(status_code, body):
    return {"statusCode": status_code,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(body)}
