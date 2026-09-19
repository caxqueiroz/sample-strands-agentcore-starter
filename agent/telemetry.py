"""OpenTelemetry integration for agent observability."""
import os
from typing import Optional
from strands.telemetry import StrandsTelemetry


class AgentTelemetry:
    """Manages OpenTelemetry setup for the agent.
    
    Provides a centralized way to configure tracing and metrics
    for the Strands agent with support for OTLP export and console debugging.
    """
    
    def __init__(self):
        """Initialize telemetry manager."""
        self._telemetry: Optional[StrandsTelemetry] = None
        self._initialized = False
    
    def setup(
        self,
        enabled: bool = True,
        otlp_endpoint: Optional[str] = None,
        console_export: bool = False,
        service_name: str = "agentcore-chat-agent"
    ) -> None:
        """Configure OpenTelemetry for the agent.
        
        Sets up tracing and metrics exporters based on configuration.
        This should be called once during agent initialization.
        
        Args:
            enabled: Whether to enable OpenTelemetry
            otlp_endpoint: OTLP collector endpoint (e.g., "http://collector:4318")
            console_export: Whether to export traces to console for debugging
            service_name: Service name for telemetry identification
        """
        if not enabled:
            return
        
        if self._initialized:
            return
        
        # Set service name for OpenTelemetry
        os.environ.setdefault("OTEL_SERVICE_NAME", service_name)
        
        # Initialize Strands telemetry
        self._telemetry = StrandsTelemetry()
        
        # Setup OTLP exporter if endpoint is provided
        if otlp_endpoint:
            os.environ.setdefault("OTEL_EXPORTER_OTLP_ENDPOINT", otlp_endpoint)
            self._telemetry.setup_otlp_exporter()
        
        # Setup console exporter for debugging
        if console_export:
            self._telemetry.setup_console_exporter()
        
        # Setup metrics with same exporters
        self._telemetry.setup_meter(
            enable_console_exporter=console_export,
            enable_otlp_exporter=bool(otlp_endpoint)
        )
        
        self._initialized = True

    def setup_arize(
        self,
        project_name: str,
        otlp_endpoint: str,
        secret_arn: Optional[str],
        region: str,
        service_name: str = "agentcore-chat-agent"
    ) -> bool:
        """Configure OpenTelemetry to export Strands traces to Arize AX.

        Registers a global TracerProvider that converts Strands spans to
        OpenInference (the format Arize renders natively) and exports them over
        OTLP gRPC. Requires the container to run without ADOT
        (``opentelemetry-instrument``), which would otherwise own the global
        provider and reject this one.

        Args:
            project_name: Arize AX project the traces are grouped under
            otlp_endpoint: Arize AX OTLP gRPC endpoint
            secret_arn: Secrets Manager secret with ``space_id`` and ``api_key``
            region: AWS region of the secret
            service_name: Service name for telemetry identification

        Returns:
            True if the exporter was configured, False if credentials are missing

        Raises:
            Exception: If the secret cannot be read
        """
        if self._initialized:
            return True

        import json
        import boto3
        from openinference.instrumentation.strands_agents import StrandsAgentsToOpenInferenceProcessor
        from opentelemetry import trace
        from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
        from opentelemetry.sdk.resources import Resource
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import BatchSpanProcessor

        if not secret_arn:
            return False
        secret = json.loads(
            boto3.client("secretsmanager", region_name=region)
            .get_secret_value(SecretId=secret_arn)["SecretString"]
        )
        space_id = (secret.get("space_id") or "").strip()
        api_key = (secret.get("api_key") or "").strip()
        if not space_id or not api_key:
            return False

        provider = TracerProvider(resource=Resource.create({
            "openinference.project.name": project_name,
            "service.name": service_name,
        }))
        # The converter must run before the exporter so Arize receives
        # OpenInference spans rather than raw Strands spans.
        provider.add_span_processor(StrandsAgentsToOpenInferenceProcessor())
        provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(
            endpoint=otlp_endpoint,
            headers={
                "arize-space-id": space_id,
                "authorization": api_key,
                "arize-interface": "python",
            },
        )))
        trace.set_tracer_provider(provider)

        self._initialized = True
        return True

    @property
    def initialized(self) -> bool:
        """Check if telemetry has been initialized."""
        return self._initialized


# Global telemetry instance
_telemetry = AgentTelemetry()


def setup_telemetry(
    enabled: bool = True,
    otlp_endpoint: Optional[str] = None,
    console_export: bool = False,
    service_name: str = "agentcore-chat-agent"
) -> None:
    """Setup OpenTelemetry for the agent.
    
    Convenience function to configure the global telemetry instance.
    
    Args:
        enabled: Whether to enable OpenTelemetry
        otlp_endpoint: OTLP collector endpoint
        console_export: Whether to export traces to console
        service_name: Service name for telemetry
    """
    _telemetry.setup(
        enabled=enabled,
        otlp_endpoint=otlp_endpoint,
        console_export=console_export,
        service_name=service_name
    )


def setup_arize_telemetry(
    project_name: str,
    otlp_endpoint: str,
    secret_arn: Optional[str],
    region: str,
    service_name: str = "agentcore-chat-agent"
) -> bool:
    """Setup OpenTelemetry to export traces to Arize AX.

    Convenience function to configure the global telemetry instance.

    Args:
        project_name: Arize AX project the traces are grouped under
        otlp_endpoint: Arize AX OTLP gRPC endpoint
        secret_arn: Secrets Manager secret with space_id and api_key
        region: AWS region of the secret
        service_name: Service name for telemetry

    Returns:
        True if the exporter was configured, False if credentials are missing
    """
    return _telemetry.setup_arize(
        project_name=project_name,
        otlp_endpoint=otlp_endpoint,
        secret_arn=secret_arn,
        region=region,
        service_name=service_name
    )


def is_telemetry_initialized() -> bool:
    """Check if telemetry has been initialized."""
    return _telemetry.initialized
