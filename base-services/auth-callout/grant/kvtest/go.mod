// A module of its own, on purpose: the embedded NATS server these tests run against
// requires newer nats.go, jwt and nkeys than the production module — and a test
// dependency must not move a production build. `replace` points at the callout; the
// server is pinned to the version the hub runs. `make test` runs this module explicitly.
module auth-callout/grant/kvtest

go 1.26.0

require (
	auth-callout v0.0.0
	github.com/nats-io/nats-server/v2 v2.14.6
	github.com/nats-io/nats.go v1.51.0
	github.com/nats-io/nkeys v0.4.16
	github.com/stretchr/testify v1.11.1
	gopkg.in/yaml.v3 v3.0.1
)

require (
	github.com/antithesishq/antithesis-sdk-go v0.7.2-default-no-op // indirect
	github.com/davecgh/go-spew v1.1.1 // indirect
	github.com/google/go-tpm v0.9.8 // indirect
	github.com/klauspost/compress v1.19.2 // indirect
	github.com/labstack/gommon v0.4.2 // indirect
	github.com/mattn/go-colorable v0.1.13 // indirect
	github.com/mattn/go-isatty v0.0.20 // indirect
	github.com/minio/highwayhash v1.0.4 // indirect
	github.com/nats-io/jwt/v2 v2.8.2 // indirect
	github.com/nats-io/nuid v1.0.1 // indirect
	github.com/pmezard/go-difflib v1.0.0 // indirect
	github.com/valyala/bytebufferpool v1.0.0 // indirect
	github.com/valyala/fasttemplate v1.2.2 // indirect
	golang.org/x/crypto v0.55.0 // indirect
	golang.org/x/sys v0.47.0 // indirect
	golang.org/x/time v0.15.0 // indirect
)

replace auth-callout => ../..
