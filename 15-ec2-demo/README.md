# 15-ec2-demo

Launch a real Docker container as an EC2 instance through the EC2 API,
then reach it three different ways: LocalEmu's own `docker exec`
shortcut, real network SSH from an in-VPC client container, and EC2
Instance Connect's ephemeral-key flow. Walks through:

1. Key pair
2. Security group + SSH ingress rule
3. `run-instances` with a user-data script (Ubuntu 22.04)
4. Verify running state; inspect the honest `PrivateIpAddress` /
   `PublicIpAddress` fields
5. Wait for sshd (baked into the image, ready in a couple of seconds)
6. Verify the Docker container is up
7. `localemu ssh --list`, plus a `docker exec` read-only check
   (`localemu ssh <id> <cmd>` itself needs a real terminal -- see below)
8. Real `ssh ubuntu@<PrivateIpAddress>` from an in-VPC client container
9. EC2 Instance Connect: push an ephemeral key with
   `send-ssh-public-key` and SSH with it inside the 60s TTL
10. `aws ssm send-command` / `get-command-invocation`: the keyless,
    AWS-native path
11. Stop -> start (container gone, then back)
12. Terminate, verify container removed

## Why there's no `ssh -p <port>` step

Earlier LocalEmu releases mapped the container's SSH port to a random
host port and tagged the instance `localemu:ssh-port`, so you could
`ssh -p <port> root@localhost` straight from your laptop. LocalEmu
1.2.0 removed both: instances now expose real port 22 on the
instance's own IP inside LocalEmu's Docker networks, the same way a
real AWS instance exposes port 22 inside its VPC, not via a host port
mapping.

LocalEmu doesn't open host-to-VPC reachability on your machine by
design (it isn't a Docker port mapper), so a bare host-side `ssh` to
`PrivateIpAddress` won't connect either -- exactly like real AWS
without a bastion or VPN. This demo shows the three paths that
actually work, matching how you'd reach a real EC2 instance: an in-VPC
client container (the bastion pattern), EC2 Instance Connect, and SSM.
`localemu ssh` remains as a fast local debugging shortcut -- it's a
`docker exec`, not SSH, so it always works regardless of networking.
Note that `localemu ssh <id> <cmd>` always attaches a TTY (`docker exec
-it`), so it needs a real terminal; it will error with "cannot attach
stdin to a TTY-enabled container" if run from a script or any other
non-interactive context. This demo script therefore only calls
`localemu ssh --list`, and uses plain `docker exec` for its own
read-only checks.

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
