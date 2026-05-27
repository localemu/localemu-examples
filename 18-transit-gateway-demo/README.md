# 18-transit-gateway-demo

Enterprise-style multi-VPC network on LocalEmu: 4 VPCs wired into a
hub-and-spoke fabric with **Transit Gateway** plus one **VPC peering**
connection, then a 10-assertion matrix that proves the data plane
really routes packets the way AWS does, including the non-transitive
deny that peering enforces.

Every command runs against LocalEmu through the standard `aws` CLI:
no `docker exec`, no pokes at internal state.

```
                    +-----------------------+
                    |        mgmt           |
                    |     (10.99.0.0/16)    |
                    |  host-mgmt (bastion)  |
                    +-----------+-----------+
                                |
                                |  VPC peering
                                |  (auto-accepted)
                                |
                    +-----------v-----------+
                    |    shared-services    |
                    |     (10.0.0.0/16)     |
                    |  host-shared :8080    |
                    +-----------+-----------+
                                |
                                |  Transit Gateway
                                |  (default RT; assoc + prop enabled)
                                |
             +------------------+------------------+
             |                                     |
   +---------v----------+              +-----------v---------+
   |      prod-app      |              |      prod-data      |
   |   (10.1.0.0/16)    |              |    (10.2.0.0/16)    |
   |     host-app       |              |     host-data       |
   +--------------------+              +---------------------+
```

## What the run proves

| From → To | Path | Expected |
|---|---|---|
| `prod-app` → `prod-data` | TGW spoke↔spoke | **allow** |
| `prod-app` → `shared-services` | TGW spoke↔spoke | **allow** |
| `prod-data` → `shared-services` | TGW spoke↔spoke | **allow** |
| `prod-data` → `prod-app` | TGW spoke↔spoke | **allow** |
| `mgmt` → `shared-services` | VPC peering | **allow** |
| `shared-services` → `mgmt` | VPC peering (reverse) | **allow** |
| `mgmt` → `prod-app` | *(no route)* | **deny** (peering is non-transitive) |
| `mgmt` → `prod-data` | *(no route)* | **deny** (peering is non-transitive) |
| `prod-app` → `:8080` on shared | TGW + HTTP | **allow**, returns body |
| `mgmt` → `:8080` on shared | peering + HTTP | **allow**, returns body |

The non-transitive denies matter: they are what makes AWS peering
different from TGW attachments, and they are a frequent source of
confusion when operators try to use peering as a shortcut into an
otherwise TGW-only fabric. LocalEmu honors the rule.

## Requires

- LocalEmu started with `EC2_VM_MANAGER=docker`
- `aws` CLI (v1 or v2) and `python3` on your machine

```sh
EC2_VM_MANAGER=docker localemu start
```

## Running

```sh
./scripts/demo.sh       # build + test, takes ~45-50s
./scripts/teardown.sh   # tear down when done
```

Each step is also runnable on its own:

```sh
./infra/01_network.sh      # VPCs, SGs, TGW, peering, routes
./infra/02_compute.sh      # one EC2 per VPC
./infra/03_service.sh      # python http.server on shared-services
./infra/04_connectivity.sh # the 10-assertion matrix
./scripts/teardown.sh
```

Ids generated during 01 and 02 are written to `.state/ids.env`; later
steps `source` that file so they do not need to re-query.

## Layout

```
18-transit-gateway-demo/
├── README.md
├── scripts/
│   ├── demo.sh           <- end-to-end orchestrator
│   └── teardown.sh       <- best-effort cleanup
├── lib/
│   └── common.sh         <- awsx wrapper, ssm_run, logging, state helpers
└── infra/
    ├── 01_network.sh     <- VPCs, subnets, SGs, TGW, peering, routes
    ├── 02_compute.sh     <- EC2 per VPC
    ├── 03_service.sh     <- HTTP service on shared-services
    └── 04_connectivity.sh <- the 10-assertion matrix
```

## What this exercises in LocalEmu

- `CreateVpc` / `CreateSubnet` with Docker-backed per-VPC network isolation.
- `CreateTransitGateway` with default-RT association + propagation.
- `CreateTransitGatewayVpcAttachment` joining three VPCs to the same TGW
  bridge.
- `CreateVpcPeeringConnection` + `AcceptVpcPeeringConnection`, with the
  peer CIDRs programmed into the source VPC's route table.
- `RunInstances` backed by real Docker containers (`t2.micro` =
  minimal Ubuntu 22.04), one per VPC, reachable via the cross-VPC fabric.
- `SSM SendCommand` + `GetCommandInvocation` for out-of-band exec: no
  SSH/keys needed to drive tests.
- `CreateRoute` with both `--transit-gateway-id` and
  `--vpc-peering-connection-id` targets so the route table describe
  output matches what Terraform/CloudFormation users expect.

## Reset

If a step fails half-way through and leaves orphan resources, nuke
everything LocalEmu-side and start fresh:

```sh
lsof -tiTCP:4566 -sTCP:LISTEN | xargs -r kill -TERM
rm -rf /var/lib/localemu/*
docker network ls --filter 'name=localemu-' -q | xargs -r docker network rm
docker ps -a --filter 'name=localemu-ec2-' -q | xargs -r docker rm -f
EC2_VM_MANAGER=docker localemu start
```
