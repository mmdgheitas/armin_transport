"""Gunicorn configuration (production). Every value can be overridden via environment."""

import os

bind = os.environ.get("BIND", "127.0.0.1:8000")
workers = int(os.environ.get("WEB_CONCURRENCY", "1"))
threads = int(os.environ.get("GUNICORN_THREADS", "4"))
worker_class = "gthread"
timeout = int(os.environ.get("GUNICORN_TIMEOUT", "120"))
graceful_timeout = 30
keepalive = 5
max_requests = 2000
max_requests_jitter = 200

# Only trust X-Forwarded-* headers from the reverse proxy (see also TRUSTED_PROXY_COUNT).
forwarded_allow_ips = os.environ.get("FORWARDED_ALLOW_IPS", "127.0.0.1")

# The application writes its own structured access log with customer tokens masked,
# so Gunicorn's raw access log (which would contain them) stays disabled.
accesslog = None
errorlog = "-"
loglevel = os.environ.get("LOG_LEVEL", "info").lower()

limit_request_line = 4094
limit_request_fields = 100
