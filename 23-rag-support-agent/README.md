# 23-rag-support-agent

A retail support agent with **real retrieval and real tool-calling** —
not a chatbot demo. Two paths, chosen by a cheap deterministic
pre-router (an order-id regex), not an LLM call: reserve the LLM for
what actually needs language understanding (grounding an answer in
unstructured FAQ text), keep structured-data lookups templated and fast.

```
question
  │
  ├─ looks like an order-status question (contains O-NNNN)?
  │     └─ check_order_status tool (real lambda:Invoke)
  │           ├─ found      -> templated answer
  │           └─ not found  -> create_support_ticket tool (real lambda:Invoke)
  │
  └─ otherwise
        └─ embed(question) -> OpenSearch k-NN search over the FAQ
           knowledge base -> generate(context + question) -> grounded answer
```

Same `LLMClient` dual-mode pattern as `08-llm-gateway` (`LLM_MODE=local`
default, `LLM_MODE=bedrock` for a real model) — except now `bedrock` mode
can point at **LocalEmu itself** (`BEDROCK_BACKEND=ollama`), not just real
AWS, thanks to this workshop's own Bedrock fix. Same code either way.

Seven integration tests: 3 knowledge-base (retrieval correctness +
grounded generation + a real similarity score, not a stub), 2 known-order
lookups, 1 two-tool chain (unknown order -> ticket), 1 input validation.

## Layout

```
23-rag-support-agent/
├── src/
│   ├── agent.py                  # router + retrieval + tool orchestration
│   ├── check_order_status.py     # tool Lambda
│   ├── create_support_ticket.py  # tool Lambda
│   ├── llm_client.py             # same dual-mode client as 08-llm-gateway
│   └── local_answers.jsonl       # canned embed/generate answers for LLM_MODE=local
├── terraform/                    # 12 resources, one provider
├── tests/test_agent.py           # 7 tests
└── scripts/{deploy,test,teardown}.sh, seed.py
```

## Two things worth knowing before you present this live

**1. The OpenSearch domain takes Terraform ~10 minutes to report
"Creation complete" — even though the domain itself is ready in seconds.**
Checked directly mid-apply: `DescribeDomain` already showed
`Processing: False` with a working endpoint well before Terraform's
"Still creating..." loop finished. This is the HashiCorp AWS provider's
own domain-ready waiter, not LocalEmu being slow — it doesn't appear to
treat LocalEmu's `Processing: False` as "done" early, and just runs its
full real-AWS-shaped wait budget. **For a live demo, deploy before you go
on stage** (or script around Terraform with the raw CLI, which returns
immediately once the domain is actually ready).

**2. The agent Lambda can't reach OpenSearch via `localhost:<port>`.**
`OPENSEARCH_ENDPOINT` (from Terraform) is a *host*-mapped address —
reachable from your laptop, not from inside the agent Lambda's own
Docker container, which is a peer container, not the host. `agent.py`
swaps `localhost`/`127.0.0.1` for `host.docker.internal` (Docker
Desktop's always-available route back to the host) before calling
OpenSearch — see `_container_reachable_endpoint`. No example in this
repo needed this before (`14-rds-demo` talks *to* its container from a
script on your laptop, never *from* a Lambda calling *into* another
sidecar container), so there was no existing convention to copy.

## Requires

```sh
localemu start   # no special flags - OpenSearch's Docker backend is on by default
```

## Running the test suite

```sh
./scripts/deploy.sh    local   # ~10 min, see caveat #1 above
./scripts/test.sh      local
./scripts/teardown.sh  local
```

## Running against real local inference (optional)

Same agent code, same Terraform, real embeddings and real generation via
Ollama instead of canned answers:

Start LocalEmu with the Ollama backend (the variable belongs to the
LocalEmu server, not to the deploy script):

```sh
BEDROCK_BACKEND=ollama localemu start
```

Then deploy with the agent and the seed script both in `bedrock` mode:

```sh
LLM_MODE=bedrock TF_VAR_llm_mode=bedrock ./scripts/deploy.sh local
LLM_MODE=bedrock ./scripts/test.sh local
```

The first call pulls the models into the Ollama sidecar (a few GB) and loads
them, so the first test run is slow. `anthropic.claude-sonnet-4-6-v1:0`, the
default chat model, is served by `llama3.1:8b` (Claude has no open weights).

(The knowledge-base retrieval tests still pass: real embeddings put the
right FAQ doc closest to the right question, same as the canned vectors
do, just for real. Run the tests with `LLM_MODE=bedrock` too: the
similarity-score assertion is relaxed in that mode, because the L2 score of
a real 768-dimension embedding is far lower than the canned vectors'.)

## Running against real AWS

```sh
TF_VAR_llm_mode=bedrock ./scripts/deploy.sh aws
./scripts/test.sh      aws
./scripts/teardown.sh  aws
```
