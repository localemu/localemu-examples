"""7 integration tests: real OpenSearch k-NN retrieval + generation (3),
real tool-calling (2), two-tool chaining (1), and an input-validation case."""
from __future__ import annotations

import os

from conftest import ask


def test_kb_question_retrieves_correct_doc_and_grounds_the_answer(lambda_client, tf):
    result = ask(lambda_client, tf["agent_function_name"], "How long do I have to send back something I bought?")
    assert result["route"] == "knowledge_base"
    assert "30 days" in result["retrieved_doc"]
    assert "30 days" in result["answer"]


def test_kb_question_different_query_retrieves_different_doc(lambda_client, tf):
    result = ask(lambda_client, tf["agent_function_name"], "Do you deliver to other countries?")
    assert result["route"] == "knowledge_base"
    assert "ship internationally" in result["retrieved_doc"]
    assert "40 countries" in result["answer"]


def test_kb_question_retrieval_score_is_a_real_similarity_not_a_stub(lambda_client, tf):
    result = ask(lambda_client, tf["agent_function_name"], "When do gift cards expire?")
    assert result["route"] == "knowledge_base"
    assert "Gift cards never expire" in result["retrieved_doc"]
    # Real OpenSearch k-NN score. The canned 4-dim vectors sit close together
    # (> 0.9); a real 768-dim embedding model gives a much smaller L2 score for
    # the same correct hit, so in bedrock mode only require a positive score.
    min_score = 0.9 if os.environ.get("LLM_MODE", "local") == "local" else 0.0
    assert result["retrieval_score"] > min_score


def test_known_order_status_uses_the_tool_lambda(lambda_client, tf):
    result = ask(lambda_client, tf["agent_function_name"], "What's the status of order O-1001?")
    assert result["route"] == "check_order_status"
    assert result["status"] == "SHIPPED"
    assert "SHIPPED" in result["answer"]


def test_another_known_order(lambda_client, tf):
    result = ask(lambda_client, tf["agent_function_name"], "Where is order O-1002?")
    assert result["status"] == "PROCESSING"


def test_unknown_order_chains_into_a_support_ticket(lambda_client, tf, dynamodb):
    result = ask(lambda_client, tf["agent_function_name"], "Can you check on order O-9999 for me?")
    assert result["route"] == "check_order_status_then_create_ticket"
    assert "ticket_id" in result

    row = dynamodb.Table(tf["tickets_table"]).get_item(Key={"ticket_id": result["ticket_id"]}).get("Item")
    assert row is not None
    assert row["status"] == "OPEN"
    assert "O-9999" in row["subject"]


def test_missing_question_is_a_clean_error_not_a_crash(lambda_client, tf):
    result = ask(lambda_client, tf["agent_function_name"], "")
    assert result["answer"] is None
    assert result["error"] == "missing_question"
