# The two test modules: the service itself, and the grant reader against a real JetStream
# store (grant/kvtest, a module of its own so its embedded server does not move the
# production build's dependencies).
.PHONY: test build

test:
	go mod tidy && go test ./...
	cd grant/kvtest && go mod tidy && go test ./...

build:
	./build.sh "$${IMAGE_REGISTRY:?set IMAGE_REGISTRY}"
