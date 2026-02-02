#! /usr/bin/env bash

set -ex

TARGET=x86_64-unknown-linux-musl
BIN_DIR=target/${TARGET}/release
VERSION=${VERSION:-$(cargo metadata --no-deps --format-version 1 | jq -r ".packages[0].version")}

echo "Compiling version ${VERSION}"
cross build -vvv --target ${TARGET} --release

docker build --target production --build-arg BIN_DIR=${BIN_DIR} -t $1/registration-server:${VERSION} .
