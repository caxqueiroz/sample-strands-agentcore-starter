# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Full-stack starter kit for agentic chat apps on AWS. It has three independently deployed parts:

- `agent/`: a Strands agent, packaged as a container and run on **Amazon Bedrock AgentCore Runtime**. Models are called through **Bedrock Mantle**, an OpenAI/Anthropic-compatible endpoint.
- `chatapp/`: a FastAPI + Jinja2 web app with a chat UI (vanilla JS SSE) and an admin dashboard (usage, cost, feedback, guardrails, evaluations, KB explorer). Data lives in DynamoDB.
- `cdk/`: TypeScript CDK with 4 stacks that deploy in this order: Foundation (Cognito, DynamoDB, IAM, Secrets) → Bedrock (Guardrail, KB on S3 Vectors, AgentCore Memory) → Agent (ECR, CodeBuild, AgentCore Runtime, Firehose→Lambda runtime-usage pipeline) → ChatApp (ECS Express and/or CloudFront + Lambda Web Adapter).

The `.kiro/steering/*.md` docs are partly stale. For example, they say the model is Claude 3.7 Sonnet, but the default is now `openai.gpt-oss-120b` via Mantle. When they disagree with the code, trust the code and README.

## Commands

### ChatApp (Python 3.11+)
```bash
cd chatapp
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt           # includes pytest, hypothesis, arel

./sync-env.sh --region <region> [--dev-mode]   # writes .env from Secrets Manager (needs deployed stacks)
uvicorn app.main:app --reload --port 8080      # DEV_RELOAD=true adds arel template/static hot reload

pytest                                         # testpaths = tests, asyncio_mode = auto
pytest tests/test_routes.py::TestHealthEndpoint::test_health_returns_200
```
- `DEV_MODE=true` bypasses Cognito and uses `DEV_USER_ID` (default `dev-user-001`).
- `app/main.py` calls `load_dotenv(override=True)`, so values in `.env` override shell env vars.

### CDK (Node 18+)
```bash
cd cdk
npm install
npm run build                  # tsc
npm test                       # jest (test/*.test.ts)
npx jest test/config.test.ts -t "<name>"
./deploy-all.sh --region <region> [--profile p] [--ingress ecs|furl|both] [--skip-chatapp] [--dry-run]
./destroy-all.sh --region <region>
npx cdk deploy htmx-chatapp-ChatApp --context ingress=furl --require-approval never   # ChatApp only
```
- **Ingress default gotcha:** `deploy-all.sh` defaults to `furl`, even though its `--help` text says `ecs`. `bin/app.ts` defaults to `ecs` when no `--context ingress=...` is passed. When running `npx cdk deploy` directly, always pass `--context ingress=<mode>`, or you may swap ingress modes by accident.
- cdk-nag `AwsSolutionsChecks` runs on synth. Findings are reported but don't block deploys; suppressions live in `lib/nag-suppressions.ts`.
- `chatapp/deploy.sh --target ecs|lambda|both` pushes ChatApp code changes without CDK.
- No local Docker is needed: all images are built by CodeBuild from S3-uploaded source.

### Agent
There is no test suite. Dependencies are in `agent/requirements.txt`. The container runs `opentelemetry-instrument python -m my_agent`, and the AgentCore SDK serves `/ping` and invocations on port 8080.

## Architecture

### Request flow
Browser → `POST /api/chat` (`chatapp/app/routes/chat.py`) → `AgentCoreClient.invoke_stream` (`app/agentcore/client.py`, boto3 `bedrock-agentcore.invoke_agent_runtime`) → agent `invoke()` in `agent/my_agent.py` → Mantle model. The agent's NDJSON output is parsed into typed SSE events (`app/models/events.py`) and streamed back.

Streaming details that matter when editing:
- The boto3 stream is blocking. `invoke_stream` reads it on a worker thread and bridges events to asyncio with `call_soon_threadsafe`. Iterating it directly on the event loop breaks token flushing and serializes compare-mode lanes.
- `_stream_chat_response` runs the generator in a producer task feeding an `asyncio.Queue` and emits `: keepalive` SSE comments every 15s. Do **not** use `asyncio.wait_for` on the async generator's `__anext__`: it corrupts the generator and causes HTTP/2 stream resets.
- After the stream ends, usage records, guardrail violations and evaluations are written **fire-and-forget** via `asyncio.create_task`. They must never block or fail the response.
- A server-measured `MetadataEvent` (`ttftMs`, `totalMs`) is emitted right before `DoneEvent` so compare-mode lanes share one clock.
- Compare mode (`static/js/compare.js`) fans the same prompt out as up to 3 concurrent `/api/chat` streams, each with its own session/memory, reusing globals from `chat.js`.

### Model catalog: `chatapp/app/static/models.json`
This file is the single source of truth for model IDs, names, pricing, tier, `api` and an optional `region`. The browser reads it, and so does Python (`app/helpers/model_catalog.py` → cost calculator, templates). Adding, removing or repricing a model needs no code changes.
- `api` selects the Strands provider in the agent: `messages` → `AnthropicModel` (base `.../anthropic`, token sent as `auth_token`/Bearer), `responses` → `OpenAIResponsesModel` (`/openai/v1`), `chat` → `OpenAIModel` (`/v1`).
- `region` pins a model to a Mantle region. The chatapp sends it as `modelRegion`, and the agent then overrides both the base URL and the region the Bedrock token is minted for, on that request only. Add it only when the default region returns 404 for that model.
- `DEFAULT_MODEL_ID` in `agent/my_agent.py` and the `model_id` default in `routes/chat.py` must match `default_model_id` in the catalog.

### Agent (`agent/my_agent.py`)
- A new `Agent` and model are built on every invocation, with a freshly minted Mantle token (`aws_bedrock_token_generator.provide_token`, valid ≤12h). If you ever cache the model or agent across requests, you must also refresh the token.
- `MemoryHook` loads the last events from AgentCore Memory into the system prompt, keyed by `actor_id=userId` from the payload and `session_id` from the runtime context. It saves only text messages (tool use/results skipped, `<thinking>` stripped). Memory errors are logged and swallowed.
- Tracing has two mutually exclusive paths chosen at deploy time. By default the container runs under `opentelemetry-instrument` (ADOT → CloudWatch/X-Ray, which also feeds AgentCore Online Evaluations). With `ARIZE_ENABLED=true` the Dockerfile skips ADOT and `telemetry.setup_arize` exports OpenInference-converted spans to Arize AX, with credentials read from the `<appName>/arize` secret. ADOT owns the global tracer provider when it runs, so any other exporter must go through this switch rather than being added alongside it.
- `NotifyOnlyGuardrailsHook` (`guardrails.py`) runs in shadow mode. It records violations, which are yielded as events at the end of the stream, and does not block.
- To add a tool, add it to `agent/tools/` and to the `tools` list in `invoke()`. **Also update `chatapp/app/evaluations/capabilities.py`**, which intentionally duplicates the agent's tool list and system-prompt claims so LLM judges don't flag real capabilities as hallucinations.

### ChatApp internals
- Layering: `routes/` (HTTP) → `storage/` (DynamoDB writes, one service per table) and `admin/*_repository.py` (analytics queries), with `models/` holding the dataclasses.
- `AuthMiddleware` (`auth/middleware.py`) authenticates against a `chatapp_session` cookie holding Cognito tokens (direct `InitiateAuth`, no hosted UI) and refreshes tokens automatically. `/admin*` requires the Cognito group `Admin`. Public routes are listed in `PUBLIC_ROUTES`/`PUBLIC_PREFIXES`.
- Evaluations (`app/evaluations/engine.py`) run binary pass/fail LLM judges (`answer_quality`, and `faithfulness` only when tools ran) plus a programmatic `tool_selection` evaluator. They are controlled by `EVALUATIONS_*` env vars.
- `FastAPI(redirect_slashes=False)` is deliberate: automatic 307s would point at the Lambda origin instead of CloudFront.

### CDK redeploy mechanics
- **Agent stack:** the `agent/` directory is an `s3assets.Asset`, and its content hash is used both as the CodeBuild `IMAGE_TAG` and as the AgentCore Runtime `containerUri` tag. That is what makes agent code changes trigger a rebuild and a runtime roll. Do not revert the runtime to `:latest` or make the build trigger's parameters static, or deploys will silently ship stale code.
- **ChatApp stack:** builds are triggered by timestamps, so every deploy rebuilds.
- Resource names come from `lib/config.ts` (`appName` default `htmx-chatapp`). IAM roles are region-suffixed so multiple regions can share an account.
- Runtime cost tracking: AgentCore `USAGE_LOGS` → Firehose → Lambda transform → DynamoDB runtime-usage table, joined to chat sessions by `session_id`.

## Conventions
- Use plain hyphens instead of em dashes in code, comments and docs (enforced by a repo-wide sweep).
- Python: dataclasses with type hints, docstrings with Args/Returns sections. JS: ES6+ with JSDoc. Templates: Tailwind via CDN, with CSS variables for theming.
- Commit style: `type(scope): subject`, with scopes like `chatapp`, `agent` and `cdk`.
