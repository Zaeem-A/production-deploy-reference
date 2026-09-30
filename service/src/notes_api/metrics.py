"""Prometheus metrics: request count and latency per route template."""

from prometheus_client import (
    CONTENT_TYPE_LATEST,
    CollectorRegistry,
    Counter,
    GCCollector,
    Histogram,
    PlatformCollector,
    ProcessCollector,
    generate_latest,
)

LATENCY_BUCKETS = (0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0)


class Metrics:
    def __init__(self) -> None:
        # A private registry (not the global default) keeps tests independent of each other.
        self.registry = CollectorRegistry()
        GCCollector(registry=self.registry)
        PlatformCollector(registry=self.registry)
        ProcessCollector(registry=self.registry)
        self.requests = Counter(
            "http_requests_total",
            "HTTP requests handled",
            ["method", "path", "status"],
            registry=self.registry,
        )
        self.latency = Histogram(
            "http_request_duration_seconds",
            "HTTP request latency in seconds",
            ["method", "path"],
            buckets=LATENCY_BUCKETS,
            registry=self.registry,
        )

    def observe(self, method: str, path: str, status: int, seconds: float) -> None:
        self.requests.labels(method=method, path=path, status=str(status)).inc()
        self.latency.labels(method=method, path=path).observe(seconds)

    def render(self) -> tuple[bytes, str]:
        return generate_latest(self.registry), CONTENT_TYPE_LATEST
