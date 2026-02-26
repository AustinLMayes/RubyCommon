#!/bin/bash

# podman  build --platform linux/amd64 -t ruby-common -f Containerfile .

# build for arm64 and amd64

podman buildx build --platform linux/amd64,linux/arm64 -t ruby-common:latest -f Containerfile .
