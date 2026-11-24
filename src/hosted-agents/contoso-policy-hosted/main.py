# Contoso policy agent as a Foundry *hosted* agent (Microsoft Agent Framework, Responses protocol).
#
# Same use case as the prompt agents in src/agents/: answer Contoso security-policy questions from the
# private Foundry IQ knowledge base, with citations. Recommended pattern: the knowledge base is a tool in
# a project TOOLBOX (azure.yaml service `contoso-policy-tools`), consumed through FoundryToolbox; the
# platform handles the tool credential (connection `knowledge-base-mcp`, project managed identity).
#
# Network path (BYO VNet): this code runs in a per-session micro VM attached to the delegated agent
# subnet. Its own calls (project endpoint: model + toolbox) use the VNet's private DNS and private
# endpoints; tool calls are executed by the Foundry tools service through the project's data proxy.
#
# Identity: platform-created agent identity (DefaultAzureCredential inside the sandbox).
# Endpoint resolution: FOUNDRY_PROJECT_ENDPOINT is injected by the platform; TOOLBOX_NAME is set in azure.yaml.
#
# Limits (a hosted agent owns its loop, so it must bound it). Agent Framework native options, set in
# azure.yaml (environmentVariables), safe defaults below:
#   HOSTED_AGENT_MAX_ITERATIONS        model round-trips per request          (max_iterations)
#   HOSTED_AGENT_MAX_TOOL_CALLS        tool calls per request                 (max_function_calls)
#   HOSTED_AGENT_TIMEOUT_SECONDS       wall-clock budget of the tool loop     (max_duration_seconds)
#                                      and HTTP timeout of each model call    (FoundryChatClient timeout)
#   HOSTED_AGENT_MAX_OUTPUT_TOKENS     cap on output tokens per model call    (max_tokens; caller values are capped)
# When a loop limit is reached the framework stops calling tools and forces a final text answer.

import asyncio
import os
from typing import Any

from agent_framework import Agent
from agent_framework.foundry import FoundryChatClient
from agent_framework_foundry_hosting import FoundryToolbox, ResponsesHostServer
from azure.identity import DefaultAzureCredential

INSTRUCTIONS = (
    "You are the Contoso security policy assistant. Answer only from the Contoso policy knowledge base. "
    "Always call the knowledge base tool before answering, cite the source documents, and say so when "
    "the knowledge base doesn't contain the answer."
)


def _limit(name: str, default: int) -> int:
    value = int(os.environ.get(name) or default)
    if value < 1:
        raise ValueError(f"{name} must be >= 1")
    return value


MAX_ITERATIONS = _limit("HOSTED_AGENT_MAX_ITERATIONS", 8)
MAX_TOOL_CALLS = _limit("HOSTED_AGENT_MAX_TOOL_CALLS", 8)
TIMEOUT_SECONDS = _limit("HOSTED_AGENT_TIMEOUT_SECONDS", 120)
MAX_OUTPUT_TOKENS = _limit("HOSTED_AGENT_MAX_OUTPUT_TOKENS", 4096)


def cap_output_tokens(_request: Any, options: dict[str, Any]) -> dict[str, Any]:
    """Callers may ask for fewer output tokens, never more than the configured cap."""
    options["max_tokens"] = min(options.get("max_tokens") or MAX_OUTPUT_TOKENS, MAX_OUTPUT_TOKENS)
    return options


async def main() -> None:
    credential = DefaultAzureCredential()

    client = FoundryChatClient(
        project_endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
        model=os.environ["AZURE_AI_MODEL_DEPLOYMENT_NAME"],
        credential=credential,
        timeout=TIMEOUT_SECONDS,
        function_invocation_configuration={
            "max_iterations": MAX_ITERATIONS,
            "max_function_calls": MAX_TOOL_CALLS,
            "max_duration_seconds": TIMEOUT_SECONDS,
        },
    )

    toolbox = FoundryToolbox(credential, approval_mode="never_require")

    agent = Agent(
        client=client,
        instructions=INSTRUCTIONS,
        tools=toolbox,
        default_options={"max_tokens": MAX_OUTPUT_TOKENS},
    )
    await ResponsesHostServer(agent, prepare_options=cap_output_tokens).run_async()


if __name__ == "__main__":
    asyncio.run(main())
