# 16-ecs-demo

End-to-end walkthrough of the LocalEmu ECS Docker backend:

1. Create a cluster
2. Register two task definitions: an `nginx:alpine` web server (port 80)
   and a `python:3.12-slim` worker that prints `tick 0`, `tick 1`, ...
3. `RunTask` each
4. Verify the real Docker containers via `docker ps`
5. Hit the nginx container with `curl` through its mapped host port
6. Tail the worker's stdout to see ticks
7. DescribeTasks on both
8. StopTask both, verify the Docker containers are gone
9. DeleteCluster

## Requires

LocalEmu started with `ECS_DOCKER_BACKEND=1`:

```sh
ECS_DOCKER_BACKEND=1 localemu start
```

## Running

```sh
./scripts/demo.sh
./scripts/teardown.sh
```
