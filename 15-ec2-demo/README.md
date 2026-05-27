# 15-ec2-demo

Launch real Docker containers as EC2 instances through the EC2 API.
Walks through:

1. Key pair
2. Security group + SSH ingress rule
3. `run-instances` with a user-data script (Ubuntu 22.04)
4. Verify the Docker container is up
5. `localemu ssh --list` and `localemu ssh <id> <cmd>`
6. Read the user-data output file from inside the instance
7. Direct `ssh -i <key> -p <mapped-port>` through the SSH port
8. Stop -> start (container gone, then back)
9. Terminate, verify container removed

## Requires

LocalEmu started with `EC2_VM_MANAGER=docker`:

```sh
EC2_VM_MANAGER=docker localemu start
```

## Running

```sh
./scripts/demo.sh
./scripts/teardown.sh
```
