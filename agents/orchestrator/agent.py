import os
import json
from typing import Any
from google.adk import Workflow, Context
from google.adk.agents.remote_a2a_agent import RemoteA2aAgent
from google.adk.agents.callback_context import CallbackContext

from authenticated_httpx import create_authenticated_client

# --- Callbacks ---
def create_save_output_callback(key: str):
    """Creates a callback to save the agent's final response to session state."""
    def callback(callback_context: CallbackContext, **kwargs) -> None:
        ctx = callback_context
        # Find the last event from this agent that has content
        for event in reversed(ctx.session.events):
            if event.author == ctx.agent_name and event.content and event.content.parts:
                text = event.content.parts[0].text
                if text:
                    # Try to parse as JSON if it looks like it, for judge_feedback
                    if key == "judge_feedback" and text.strip().startswith("{"):
                        try:
                            ctx.state[key] = json.loads(text)
                        except json.JSONDecodeError:
                            ctx.state[key] = text
                    else:
                        ctx.state[key] = text
                    print(f"[{ctx.agent_name}] Saved output to state['{key}']")
                    return
    return callback

# --- Remote Agents ---

# Connect to the Researcher (Localhost port 8001)
researcher_url = os.environ.get("RESEARCHER_AGENT_CARD_URL", "http://localhost:8001/a2a/agent/.well-known/agent-card.json")
researcher = RemoteA2aAgent(
    name="researcher",
    agent_card=researcher_url,
    description="Gathers information using Google Search.",
    # IMPORTANT: Save the output to state for the Judge to see
    after_agent_callback=create_save_output_callback("research_findings"),
    # IMPORTANT: Use authenticated client for communication
    httpx_client=create_authenticated_client(researcher_url)
)

# Connect to the Judge (Localhost port 8002)
judge_url = os.environ.get("JUDGE_AGENT_CARD_URL", "http://localhost:8002/a2a/agent/.well-known/agent-card.json")
judge = RemoteA2aAgent(
    name="judge",
    agent_card=judge_url,
    description="Evaluates research.",
    after_agent_callback=create_save_output_callback("judge_feedback"),
    httpx_client=create_authenticated_client(judge_url)
)

# Content Builder (Localhost port 8003)
content_builder_url = os.environ.get("CONTENT_BUILDER_AGENT_CARD_URL", "http://localhost:8003/a2a/agent/.well-known/agent-card.json")
content_builder = RemoteA2aAgent(
    name="content_builder",
    agent_card=content_builder_url,
    description="Builds the course.",
    httpx_client=create_authenticated_client(content_builder_url)
)

# --- Escalation Checker ---

def check_feedback(ctx: Context, node_input: Any) -> str:
    """Checks the judge's feedback and routes the workflow accordingly."""
    # Retrieve the feedback saved by the Judge in state
    feedback = ctx.session.state.get("judge_feedback")
    print(f"[check_feedback] Feedback: {feedback}")

    # Check for 'pass' status
    is_pass = False
    if isinstance(feedback, dict) and feedback.get("status") == "pass":
        is_pass = True
    elif isinstance(feedback, str) and '"status": "pass"' in feedback:
        is_pass = True
    # Fallback checking node_input directly
    elif hasattr(node_input, "status") and getattr(node_input, "status") == "pass":
        is_pass = True
    elif isinstance(node_input, dict) and node_input.get("status") == "pass":
        is_pass = True
    elif isinstance(node_input, str) and '"status": "pass"' in node_input:
        is_pass = True

    if is_pass:
        return "pass"
    else:
        return "fail"

# --- Orchestration ---

root_agent = Workflow(
    name="course_creation_pipeline",
    description="A pipeline that researches a topic and then builds a course from it.",
    edges=[
        ("START", researcher),
        (researcher, judge),
        (judge, check_feedback),
        (check_feedback, content_builder, "pass"),
        (check_feedback, researcher, "fail"),
    ],
)
