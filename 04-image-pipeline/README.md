# 04-image-pipeline

S3 upload → Lambda (Pillow thumbnail) → S3 thumbnail + SNS notification +
CloudWatch metric. Real PNGs, real thumbnails, real SNS delivery.

## Layout

```
04-image-pipeline/
├── src/handler.py + requirements.txt
├── terraform/                  # 8 resources
├── tests/test_pipeline.py      # 2 tests
└── scripts/{build,deploy,test,teardown}.sh
```

## Running locally

```sh
localemu start                    # in another terminal
./scripts/deploy.sh    local      # builds the zip then applies terraform
./scripts/test.sh      local
./scripts/teardown.sh  local
```

The build step uses `pip install --platform manylinux2014_x86_64
--only-binary=:all:` so Pillow's Linux wheels ship in the zip regardless
of the host OS. No Docker required for the build itself.
