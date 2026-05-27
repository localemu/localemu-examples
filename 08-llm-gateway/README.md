# 08-llm-gateway

A production-shaped LLM gateway with five steps per request and a
background quality-scoring loop:

    input guardrail -> semantic cache -> generate -> output guardrail
                                                       |
                                                       v
                                              EventBridge -> SQS -> judge Lambda

Runs end-to-end on LocalEmu. The LLM call itself is the one piece
LocalEmu cannot run (Bedrock is a hosted model service, not an API
surface like S3), so the application talks to the model through a small
`LLMClient` interface with two implementations: a local one that reads
pre-written answers from a JSON file, and a Bedrock-backed one for
production. The default is local:

    LLM_MODE=local   -> LocalLLMClient   (reads src/local_answers.jsonl)
    LLM_MODE=bedrock -> BedrockLLMClient

Same Lambda code, same Terraform, both worlds.

## Layout

```
08-llm-gateway/
├── src/                     # Lambda code (gateway + judge + shared llm_client)
│   ├── llm_client.py
│   ├── gateway.py
│   ├── judge.py
│   └── local_answers.jsonl   # pre-written answers for the local LLM client
├── terraform/                # 19 resources, one provider
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
├── tests/                    # 6 integration tests
│   ├── conftest.py
│   └── test_gateway.py
└── scripts/
    ├── deploy.sh
    ├── test.sh
    └── teardown.sh
```

## Running locally

```sh
localemu start                    # in another terminal
./scripts/deploy.sh    local
./scripts/test.sh      local
./scripts/teardown.sh  local
```

## Running against real AWS

Deploy the same Terraform with `aws` and set `LLM_MODE=bedrock` (you
need real AWS credentials and Bedrock model access in your region):

```sh
TF_VAR_llm_mode=bedrock ./scripts/deploy.sh aws
./scripts/test.sh      aws
./scripts/teardown.sh  aws
```
