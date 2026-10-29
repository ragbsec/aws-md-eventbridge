"""Health endpoint for the EventBridge global-endpoint Route 53 health check.

Returns 200 when HEALTHY=true (the default), 503 otherwise. Flipping the
function's HEALTHY env var to "false" simulates a primary-region outage so the
Route 53 health check goes Unhealthy and EventBridge fails events over to the
secondary region — the live failover test.
"""
import os


def handler(event, context):
    healthy = os.environ.get("HEALTHY", "true").lower() == "true"
    if healthy:
        return {
            "statusCode": 200,
            "headers": {"content-type": "application/json"},
            "body": '{"status":"ok"}',
        }
    return {
        "statusCode": 503,
        "headers": {"content-type": "application/json"},
        "body": '{"status":"unhealthy"}',
    }
