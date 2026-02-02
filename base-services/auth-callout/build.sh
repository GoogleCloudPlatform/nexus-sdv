#! /usr/bin/env bash

IMAGE_REGISTRY=$1

if [ -z "$IMAGE_REGISTRY" ]; then
  echo "Error: IMAGE_REGISTRY is empty. Exiting."
  exit 1
fi

export APP_VERSION=$(cat VERSION)

# tidy up the go modules
go mod tidy

# docker build container
docker build -t "$IMAGE_REGISTRY/nats-auth-callout:$APP_VERSION" .
