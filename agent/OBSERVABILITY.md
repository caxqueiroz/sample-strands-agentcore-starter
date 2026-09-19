# Observability with OpenTelemetry

This agent includes built-in OpenTelemetry (OTEL) support for comprehensive observability.

## What Gets Traced

The agent automatically captures:

- **Agent-level spans**: Complete invocation with total token usage and session context
- **Cycle spans**: Each reasoning loop iteration with prompts and responses
- **Model invocation spans**: Prompts, completions, token usage, and cache hits
- **Tool execution spans**: Tool calls with inputs, outputs, and timing
- **Custom attributes**: Session ID, user ID, memory ID, and deployment environment

## Configuration

### Environment Variables

```bash
# Enable/disable OpenTelemetry (default: true)
OTEL_ENABLED=true

# OTLP collector endpoint (optional)
OTEL_EXPORTER_OTLP_ENDPOINT=http://collector.example.com:4318

# OTLP headers for authentication (optional)
OTEL_EXPORTER_OTLP_HEADERS=key1=value1,key2=value2

# Console export for debugging (default: false)
OTEL_CONSOLE_EXPORT=true

# Service name (default: agentcore-chat-agent)
OTEL_SERVICE_NAME=my-custom-agent

# Sampling configuration (optional)
OTEL_TRACES_SAMPLER=traceidratio
OTEL_TRACES_SAMPLER_ARG=0.5  # Sample 50% of traces
```

### Local Development

For local testing with Jaeger:

```bash
# Start Jaeger all-in-one container
docker run -d --name jaeger \
  -e COLLECTOR_OTLP_ENABLED=true \
  -p 16686:16686 \
  -p 4317:4317 \
  -p 4318:4318 \
  jaegertracing/all-in-one:latest

# Configure agent to send traces to Jaeger
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318

# Or enable console export for debugging
export OTEL_CONSOLE_EXPORT=true

# Run agent
agentcore run --agent my_agent
```

Access Jaeger UI at http://localhost:16686

## Arize AX Integration

Agent traces can be sent to [Arize AX](https://arize.com/docs/ax/integrations/python-agent-frameworks/aws-strands/bedrock-agentcore) instead of CloudWatch/X-Ray. It is opt-in and set at deploy time.

### Enable

```bash
cd cdk
ARIZE_ENABLED=true ARIZE_PROJECT_NAME=my-project ./deploy-all.sh --region us-east-1 --ingress furl

# Then store your Arize space ID and API key (Arize AX > Settings)
aws secretsmanager put-secret-value --region us-east-1 \
  --secret-id htmx-chatapp/arize \
  --secret-string '{"space_id":"<space-id>","api_key":"<api-key>"}'
```

The agent reads the secret when a runtime session starts, so no redeploy is needed after setting it. Until it is filled in, the agent logs a warning and exports no traces.

| Deploy-time variable | Default | Purpose |
|----------------------|---------|---------|
| `ARIZE_ENABLED` | `false` | Turn on Arize AX export |
| `ARIZE_PROJECT_NAME` | app name (`htmx-chatapp`) | Arize AX project for the traces |
| `ARIZE_OTLP_ENDPOINT` | `https://otlp.arize.com:443` | OTLP gRPC endpoint |

### How it works

- The container starts without `opentelemetry-instrument` and the runtime sets `DISABLE_ADOT_OBSERVABILITY=true`. ADOT would otherwise own the global tracer provider and reject the Arize one.
- `telemetry.py` registers a tracer provider that runs `StrandsAgentsToOpenInferenceProcessor` (so Arize renders agent, LLM, tool and chain spans natively) followed by an OTLP gRPC exporter authenticated with the secret's values.
- `session.id` and `user.id` from the agent's trace attributes carry through, so traces group by chat session and user in Arize.

### Trade-offs

With Arize enabled, the agent's own spans no longer reach CloudWatch, which affects:
- the CloudWatch GenAI Observability dashboard and the admin UI's CloudWatch trace links
- AgentCore Online Evaluations (`OnlineEvalConfig`), which scores agent spans read from CloudWatch

Runtime application logs, usage logs (cost tracking) and the chat app's own evaluations are unaffected.

## CloudWatch X-Ray Integration

AgentCore Runtime automatically instruments your agent when `aws-opentelemetry-distro` is in requirements.txt.

### Automated Setup

Run the observability setup script to enable full observability:

```bash
# From the agent directory (auto-detects runtime ARN from config)
./deploy/setup-observability.sh

# With explicit runtime ARN
./deploy/setup-observability.sh --runtime-arn arn:aws:bedrock-agentcore:us-east-1:123456789:runtime/htmx_chatapp

# With SNS notifications for alarms
./deploy/setup-observability.sh --sns-topic-arn arn:aws:sns:us-east-1:123456789:my-alerts

# Or run as part of the full deployment
./setup.sh --sns-topic-arn arn:aws:sns:us-east-1:123456789:my-alerts
```

This script configures:
1. **CloudWatch Transaction Search** (one-time per account) - enables X-Ray traces in CloudWatch
2. **Runtime Log Delivery** - sends application logs to CloudWatch Logs
3. **Runtime Tracing** - sends traces to X-Ray for the GenAI Observability dashboard
4. **Metric Filters** - for errors, invocations, and tool usage
5. **CloudWatch Alarms** - for error rate and availability monitoring

### Console Setup (Alternative)

You can also enable log delivery and tracing via the AgentCore console:

1. Go to [AgentCore Runtime Console](https://console.aws.amazon.com/bedrock-agentcore/agents)
2. Select your agent (htmx_chatapp)
3. In **Log delivery** section:
   - Click **Add** → Select **CloudWatch Logs**
   - Set Log type to **APPLICATION_LOGS**
   - Click **Add**
4. In **Tracing** section:
   - Click **Edit** → Toggle to **Enable** → **Save**
5. For Identity tracing:
   - Go to **Identity** tab
   - In **Tracing** section, click **Edit** → **Enable** → **Save**

### Manual Setup

If you prefer manual setup:

```bash
# Enable Transaction Search (one-time)
aws xray update-trace-segment-destination --destination CloudWatchLogs

# Create error metric filter
aws logs put-metric-filter \
  --log-group-name "/aws/bedrock-agentcore/runtimes/<agent-id>/runtime-logs" \
  --filter-name "AgentErrors" \
  --filter-pattern "ERROR" \
  --metric-transformations metricName=AgentErrorCount,metricNamespace=AgentCore/Chat,metricValue=1
```

### View Traces

After setup, view your observability data:

- **GenAI Dashboard**: [CloudWatch → GenAI Observability → AgentCore](https://console.aws.amazon.com/cloudwatch/home#gen-ai-observability/agent-core/agents)
  - View agents, sessions, and traces
  - Analyze agent performance and token usage
- **Transaction Search**: CloudWatch → X-Ray traces → Transaction Search
- **Custom Metrics**: CloudWatch → Metrics → AgentCore/Chat
- **Runtime Logs**: CloudWatch → Log groups → `/aws/vendedlogs/bedrock-agentcore/runtime/<runtime-id>`

## Metrics Available

The agent logs comprehensive metrics after each invocation:

- **Duration**: Total execution time
- **Memory**: Average memory usage
- **Cycles**: Number of reasoning cycles
- **Tokens**: Total token usage (input + output)
- **Tools**: List of tools used with call counts and success rates

Example log output:
```
Invocation complete - Duration: 2.45s, Memory: 156.32MB (0.1526GB), 
Session: abc-123, Cycles: 2, Tokens: 4004, Tools used: ['calculator']
```

## Trace Attributes

Each trace includes custom attributes for filtering and analysis:

- `session.id`: User session identifier
- `user.id`: User identifier (from Cognito)
- `agent.version`: Agent version timestamp
- `deployment.environment`: Deployment environment (production/staging/dev)
- `memory.id`: AgentCore Memory ID

## Best Practices

1. **Production**: Use OTLP endpoint with sampling to reduce data volume
   ```bash
   OTEL_EXPORTER_OTLP_ENDPOINT=http://collector:4318
   OTEL_TRACES_SAMPLER=traceidratio
   OTEL_TRACES_SAMPLER_ARG=0.1  # Sample 10%
   ```

2. **Development**: Enable console export for immediate feedback
   ```bash
   OTEL_CONSOLE_EXPORT=true
   ```

3. **Debugging**: Disable sampling to capture all traces
   ```bash
   OTEL_TRACES_SAMPLER=always_on
   ```

4. **Cost Optimization**: Monitor token usage in traces to identify expensive operations

5. **Security**: Avoid capturing PII in trace attributes (user IDs are hashed by default)

## Visualization Tools

Compatible with any OpenTelemetry-compatible tool:

- **Jaeger**: Open-source distributed tracing
- **AWS X-Ray**: AWS-native tracing and service maps
- **Grafana Tempo**: Scalable distributed tracing backend
- **Datadog**: Full-stack observability platform
- **Honeycomb**: Observability for complex systems
- **Langfuse**: AI-specific observability with evals and prompt management

## Troubleshooting

### No traces appearing

1. Check OTLP endpoint is accessible:
   ```bash
   curl -v http://collector:4318/v1/traces
   ```

2. Enable console export to verify traces are being generated:
   ```bash
   export OTEL_CONSOLE_EXPORT=true
   ```

3. Check agent logs for telemetry initialization:
   ```
   OpenTelemetry initialized - endpoint: http://collector:4318, console: false
   ```

### High data volume

Implement sampling:
```bash
export OTEL_TRACES_SAMPLER=traceidratio
export OTEL_TRACES_SAMPLER_ARG=0.1  # 10% sampling
```

### Missing context

Ensure trace context is propagated across service boundaries using standard OTEL headers.

## Further Reading

- [Strands Agents Observability Guide](https://strandsagents.com/latest/documentation/docs/user-guide/observability-evaluation/observability/)
- [OpenTelemetry Python Documentation](https://opentelemetry.io/docs/languages/python/)
- [AWS X-Ray with OpenTelemetry](https://aws-otel.github.io/docs/getting-started/x-ray)
