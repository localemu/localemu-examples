"""The LLMClient interface and its two implementations.

The whole point of this file is the separation between *how* the
application asks the LLM for something (the LLMClient interface) and
*who* answers (the two concrete classes below).

LocalLLMClient   -- reads pre-written answers from a JSON file.
                    Used during development, in tests, and on LocalEmu
                    because Bedrock cannot run locally.

BedrockLLMClient -- calls the real Bedrock service.
                    Used in production (or anywhere you actually want
                    a live model).

A single environment variable, LLM_MODE, picks which one is live:

    LLM_MODE=local   -> LocalLLMClient   (the default)
    LLM_MODE=bedrock -> BedrockLLMClient

Everything else in the application is identical in both modes.
"""
from __future__ import annotations

import json
import math
import os
import re
from typing import Protocol


class LLMClient(Protocol):
    """The four things the application asks an LLM to do."""

    def classify(self, text: str, *, rubric: str) -> dict: ...
    def embed(self, text: str) -> list[float]: ...
    def generate(self, prompt: str) -> str: ...
    def judge(self, *, query: str, response: str, rubric: str) -> dict: ...


class LocalLLMClient:
    """An LLMClient that returns pre-written answers from a JSON file.

    Each line of the file is a JSON object with three fields:

        step:     which method the entry answers ("classify", "embed",
                  "generate", or "judge"). For classify, the rubric is
                  folded into the step name as "guardrail_input" or
                  "guardrail_output".
        pattern:  a regex matched against the input. First match wins.
        response: the value to return when the pattern matches.

    This file replaces the need for a real LLM during local development
    and in tests. Two questions phrased differently can be made to return
    the same embedding vector simply by writing one entry whose pattern
    matches both, which is how the semantic-cache test stays deterministic.
    """

    def __init__(self, answers_path: str) -> None:
        self._by_step: dict[str, list[tuple[re.Pattern[str], dict]]] = {}
        with open(answers_path, "r", encoding="utf-8") as f:
            for raw_line in f:
                line = raw_line.strip()
                if not line or line.startswith("#"):
                    continue
                entry = json.loads(line)
                step = entry["step"]
                pattern = re.compile(entry["pattern"])
                response = entry["response"]
                self._by_step.setdefault(step, []).append((pattern, response))

    def _lookup(self, step: str, text: str) -> dict:
        for pat, resp in self._by_step.get(step, []):
            if pat.search(text):
                return resp
        raise LookupError(
            f"no local answer matches step={step!r} for input={text!r}"
        )

    def classify(self, text: str, *, rubric: str) -> dict:
        # rubric is "input_guardrail" or "output_guardrail";
        # the answers file groups these as guardrail_input / guardrail_output.
        if rubric == "input_guardrail":
            step = "guardrail_input"
        elif rubric == "output_guardrail":
            step = "guardrail_output"
        else:
            step = f"guardrail_{rubric.replace('_guardrail', '')}"
        return self._lookup(step, text)

    def embed(self, text: str) -> list[float]:
        return list(self._lookup("embed", text)["vector"])

    def generate(self, prompt: str) -> str:
        return self._lookup("generate", prompt)["text"]

    def judge(self, *, query: str, response: str, rubric: str) -> dict:
        return self._lookup("judge", query)


class BedrockLLMClient:
    """An LLMClient that calls real Bedrock. Used in production only.

    The two methods that the local client routes through the answers
    file (classify/judge) are intentionally not wired here: in
    production those go through Bedrock Guardrails and a dedicated
    judge-model call respectively, both of which are out of scope for
    this tutorial. Embed and generate are wired so you can see the
    shape of a real Bedrock call alongside the local equivalent.
    """

    def __init__(self) -> None:
        import boto3  # lazy: local mode does not need boto3 for the LLM

        self._bedrock = boto3.client("bedrock-runtime")
        self._chat_model = os.environ.get(
            "BEDROCK_CHAT_MODEL", "anthropic.claude-sonnet-4-6-v1:0"
        )
        self._embed_model = os.environ.get(
            "BEDROCK_EMBED_MODEL", "amazon.titan-embed-text-v2:0"
        )

    def classify(self, text: str, *, rubric: str) -> dict:
        raise NotImplementedError(
            "wire this to Bedrock Guardrails in production"
        )

    def embed(self, text: str) -> list[float]:
        resp = self._bedrock.invoke_model(
            modelId=self._embed_model,
            body=json.dumps({"inputText": text}).encode(),
        )
        return list(json.loads(resp["body"].read())["embedding"])

    def generate(self, prompt: str) -> str:
        resp = self._bedrock.invoke_model(
            modelId=self._chat_model,
            body=json.dumps(
                {
                    "anthropic_version": "bedrock-2023-05-31",
                    "max_tokens": 512,
                    "messages": [{"role": "user", "content": prompt}],
                }
            ).encode(),
        )
        payload = json.loads(resp["body"].read())
        return payload["content"][0]["text"]

    def judge(self, *, query: str, response: str, rubric: str) -> dict:
        raise NotImplementedError(
            "wire this to a judge-model invoke_model call in production"
        )


def get_client() -> LLMClient:
    """Return the LLMClient picked by the LLM_MODE environment variable.

    Defaults to "local" so that fresh checkouts work without an AWS
    account or Bedrock access.
    """
    mode = os.environ.get("LLM_MODE", "local")
    if mode == "local":
        return LocalLLMClient(os.environ["LLM_LOCAL_ANSWERS_PATH"])
    if mode == "bedrock":
        return BedrockLLMClient()
    raise ValueError(f"unknown LLM_MODE: {mode!r} (expected 'local' or 'bedrock')")


def cosine(a: list[float], b: list[float]) -> float:
    """Cosine similarity between two vectors, in [-1, 1]."""
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    if na == 0 or nb == 0:
        return 0.0
    return dot / (na * nb)
