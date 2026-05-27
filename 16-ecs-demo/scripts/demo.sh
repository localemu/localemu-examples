#!/usr/bin/env bash
# End-to-end ECS walkthrough: cluster, register 2 task definitions
# (nginx + python worker), run-task for each, verify real Docker
# containers, curl nginx on its mapped port, stop, delete cluster.
#
# Requires: LocalEmu started with ECS_DOCKER_BACKEND=1
set -euo pipefail

export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
export AWS_DEFAULT_REGION=us-east-1
ENDPOINT="--endpoint-url=http://localhost:4566"

CLUSTER=le-demo-ecs

bold() { printf "\n\033[1;36m== %s ==\033[0m\n" "$1"; }

# Clean slate
docker ps --filter 'label=localemu.service=ecs' --format '{{.Names}}' | xargs -r docker rm -f >/dev/null 2>&1 || true
aws $ENDPOINT ecs delete-cluster --cluster "$CLUSTER" 2>/dev/null || true
sleep 1

bold "1. Create cluster"
aws $ENDPOINT ecs create-cluster --cluster-name "$CLUSTER" \
  --query 'cluster.{Name:clusterName,Status:status,Tasks:runningTasksCount}'

bold "2. Register task definition: web-server (nginx:alpine, port 80)"
aws $ENDPOINT ecs register-task-definition \
  --family le-web \
  --container-definitions '[{
    "name": "nginx",
    "image": "nginx:alpine",
    "portMappings": [{"containerPort": 80, "hostPort": 0, "protocol": "tcp"}],
    "essential": true,
    "memory": 128
  }]' \
  --query 'taskDefinition.{Family:family,Revision:revision,Arn:taskDefinitionArn,Status:status}'

bold "3. Register task definition: python-worker (python:3.12-slim, prints ticks)"
aws $ENDPOINT ecs register-task-definition \
  --family le-worker \
  --container-definitions '[{
    "name": "worker",
    "image": "python:3.12-slim",
    "command": ["python", "-c", "import time, sys\nfor i in range(60):\n    print(f\"tick {i}\", flush=True)\n    time.sleep(1)"],
    "essential": true,
    "memory": 256
  }]' \
  --query 'taskDefinition.{Family:family,Revision:revision,Arn:taskDefinitionArn,Status:status}'

bold "4. List registered task definitions"
aws $ENDPOINT ecs list-task-definitions --query 'taskDefinitionArns'

bold "5. RunTask le-web (nginx)"
WEB_TASK_ARN=$(aws $ENDPOINT ecs run-task --cluster "$CLUSTER" --task-definition le-web \
  --query 'tasks[0].taskArn' --output text)
WEB_TASK_ID="${WEB_TASK_ARN##*/}"
echo "   web task arn = $WEB_TASK_ARN"

bold "6. RunTask le-worker (python)"
WORKER_TASK_ARN=$(aws $ENDPOINT ecs run-task --cluster "$CLUSTER" --task-definition le-worker \
  --query 'tasks[0].taskArn' --output text)
WORKER_TASK_ID="${WORKER_TASK_ARN##*/}"
echo "   worker task arn = $WORKER_TASK_ARN"

sleep 3  # let containers fully start

bold "7. Verify real Docker containers"
docker ps --filter "label=localemu.service=ecs" \
  --format 'table {{.Image}}\t{{.Status}}\t{{.Ports}}\t{{.Names}}'

bold "8. curl the nginx container through its mapped port"
# ECS on LocalEmu does not populate containers[].networkBindings in describe-tasks,
# so grab the host port directly from Docker.
NGINX_CONTAINER=$(docker ps --filter "label=localemu.service=ecs" \
  --filter "label=localemu.task-id=$WEB_TASK_ID" --format '{{.Names}}' | head -1)
if [[ -z "$NGINX_CONTAINER" ]]; then
  NGINX_CONTAINER=$(docker ps --filter "label=localemu.service=ecs" --format '{{.Names}}' | grep -i nginx | head -1)
fi
NGINX_PORT=$(docker port "$NGINX_CONTAINER" 80/tcp 2>/dev/null | awk -F: 'NR==1{print $NF}')
echo "   nginx container = $NGINX_CONTAINER"
echo "   nginx host port = $NGINX_PORT"
for i in 1 2 3 4 5; do
  if out=$(curl -s -m 3 "http://localhost:$NGINX_PORT/" 2>/dev/null) && [[ -n "$out" ]]; then
    echo "$out" | head -4
    break
  fi
  sleep 2
done

bold "9. Verify the worker is printing ticks"
WORKER_NAME=$(docker ps --filter "label=localemu.service=ecs" \
  --filter "label=localemu.task-id=$WORKER_TASK_ID" --format '{{.Names}}' | head -1)
if [[ -z "$WORKER_NAME" ]]; then
  WORKER_NAME=$(docker ps --filter "label=localemu.service=ecs" --format '{{.Names}}' | grep -i worker | head -1)
fi
if [[ -n "$WORKER_NAME" ]]; then
  echo "   tailing 3 log lines from $WORKER_NAME"
  docker logs --tail 3 "$WORKER_NAME" 2>&1 | head -5
else
  echo "   (could not find worker container by label; skipping tail)"
fi

bold "10. DescribeTasks on both tasks"
aws $ENDPOINT ecs describe-tasks --cluster "$CLUSTER" \
  --tasks "$WEB_TASK_ID" "$WORKER_TASK_ID" \
  --query 'tasks[].{Id:taskArn,Status:lastStatus,TaskDef:taskDefinitionArn}' --output table

bold "11. StopTask both"
# LocalEmu papercut: stop-task looks up tasks by FULL ARN, not UUID alone.
# Real AWS accepts both. Pass the ARN to be safe on both targets.
aws $ENDPOINT ecs stop-task --cluster "$CLUSTER" --task "$WEB_TASK_ARN"    --query 'task.lastStatus' --output text
aws $ENDPOINT ecs stop-task --cluster "$CLUSTER" --task "$WORKER_TASK_ARN" --query 'task.lastStatus' --output text

bold "12. Verify containers are gone"
sleep 2
remaining=$(docker ps --filter "label=localemu.service=ecs" --format '{{.Names}}' | wc -l | tr -d ' ')
if [[ "$remaining" == "0" ]]; then
  echo "  all ecs containers gone"
else
  echo "  WARNING: $remaining ecs containers still running"
  docker ps --filter "label=localemu.service=ecs" --format '  {{.Names}}'
fi

bold "13. Delete cluster"
aws $ENDPOINT ecs delete-cluster --cluster "$CLUSTER" \
  --query 'cluster.{Name:clusterName,Status:status}'

echo
echo "→ demo complete."
