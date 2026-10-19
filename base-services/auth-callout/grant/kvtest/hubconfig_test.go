// The grant path against the hub's own configuration — accounts, users, permissions,
// the callout block — loaded from the helmfile into an embedded server. This is the test
// that shows what a bare server cannot: whether JetStream is available where the buckets
// are, and whether the two users may do what they must. (Review of 2026-09-28, finding
// C2: the spec had put the buckets in $G, which cannot have JetStream once named accounts
// exist.)
package kvtest

import (
	"bytes"
	"context"
	"encoding/json"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"auth-callout/grant"

	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/nats-io/nkeys"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"gopkg.in/yaml.v3"
)

const helmfile = "../../../../iac/helm/helmfile.d/nats.yaml.gotmpl"

// Test values for every requiredEnv the block names. The issuer must be a real account
// public key or the server refuses the callout block.
func testValues(t *testing.T) map[string]string {
	t.Helper()
	kp, err := nkeys.CreateAccount()
	require.NoError(t, err)
	pub, err := kp.PublicKey()
	require.NoError(t, err)
	return map[string]string{
		"NATS_AUTH_CALLOUT_PASSWORD": "callout-pw",
		"NATS_BASIC_AUTH_USER":       "basic",
		"NATS_BASIC_AUTH_PASSWORD":   "basic-pw",
		"NATS_CONNECTOR_PASSWORD":    "connector-pw",
		"NATS_GRANT_READER_PASSWORD": "reader-pw",
		"NATS_REGISTRY_PASSWORD":     "registry-pw",
		"NATS_AUTH_CALLOUT_NKEY_PUB": pub,
	}
}

// hubConfig returns the `config.merge` block of the helmfile as the JSON the chart writes
// into nats.conf, with the template expressions replaced by test values and the template
// control lines removed.
func hubConfig(t *testing.T) map[string]any {
	t.Helper()
	raw, err := os.ReadFile(helmfile)
	require.NoError(t, err, "the helmfile must be reachable from this module")
	text := string(raw)
	start := strings.Index(text, "      - config:\n          merge:\n")
	require.Greater(t, start, 0, "the config.merge block")
	end := strings.Index(text[start:], "\n    set:\n")
	require.Greater(t, end, 0)
	block := text[start+len("      - config:\n") : start+end]

	values := testValues(t)
	reqEnv := regexp.MustCompile(`\{\{ requiredEnv "([A-Z_]+)" \}\}`)
	block = reqEnv.ReplaceAllStringFunc(block, func(m string) string {
		name := reqEnv.FindStringSubmatch(m)[1]
		v, ok := values[name]
		require.True(t, ok, "no test value for %s", name)
		return v
	})
	var kept []string
	for _, line := range strings.Split(block, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "{{") { // {{- if … }}, {{- end }}
			continue
		}
		if strings.Contains(line, "{{") { // advertise, under a base domain we do not set
			continue
		}
		kept = append(kept, strings.TrimPrefix(line, "          "))
	}
	var parsed struct {
		Merge map[string]any `yaml:"merge"`
	}
	require.NoError(t, yaml.Unmarshal([]byte(strings.Join(kept, "\n")), &parsed))
	return parsed.Merge
}

func startHub(t *testing.T) string {
	t.Helper()
	merge := hubConfig(t)
	// Ports and stores are the test's; the rest is the hub's.
	merge["listen"] = "127.0.0.1:-1"
	merge["http"] = "127.0.0.1:0"
	delete(merge, "leafnodes")
	merge["jetstream"] = map[string]any{"store_dir": t.TempDir()}
	merge["system_account"] = "SYS"
	// Go's JSON encoder escapes ">" as \u003e by default; nats-server's parser knows no
	// \u escapes, and every permission list here carries a ">".
	var confJSON bytes.Buffer
	enc := json.NewEncoder(&confJSON)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	require.NoError(t, enc.Encode(merge))
	conf := filepath.Join(t.TempDir(), "nats.conf")
	require.NoError(t, os.WriteFile(conf, confJSON.Bytes(), 0o600))

	opts, err := server.ProcessConfigFile(conf)
	require.NoError(t, err, "the hub configuration must be a valid nats-server configuration")
	opts.NoLog, opts.NoSigs = true, true
	s, err := server.NewServer(opts)
	require.NoError(t, err)
	go s.Start()
	require.True(t, s.ReadyForConnections(5*time.Second))
	t.Cleanup(s.Shutdown)
	return s.ClientURL()
}

func TestTheRegistryCanCreateTheBucketWhereTheVehiclesAre(t *testing.T) {
	url := startHub(t)
	nc, err := nats.Connect(url, nats.UserInfo("nexus-registry", "registry-pw"))
	require.NoError(t, err)
	defer nc.Close()
	js, err := jetstream.New(nc)
	require.NoError(t, err)
	_, err = js.CreateKeyValue(context.Background(), jetstream.KeyValueConfig{Bucket: grant.Bucket})
	require.NoError(t, err, "JetStream must be enabled for the account the registry and the vehicles share")
}

func TestTheCalloutReadsAGrantWithExactlyItsPermissions(t *testing.T) {
	url := startHub(t)
	writer, err := nats.Connect(url, nats.UserInfo("nexus-registry", "registry-pw"))
	require.NoError(t, err)
	defer writer.Close()
	js, err := jetstream.New(writer)
	require.NoError(t, err)
	kv, err := js.CreateKeyValue(context.Background(), jetstream.KeyValueConfig{Bucket: grant.Bucket})
	require.NoError(t, err)
	_, err = kv.Put(context.Background(), "WBA123", []byte(`{"pub":["pubsub.WBA123.pressure"],"sub":[]}`))
	require.NoError(t, err)

	src, err := grant.NewKV(url, "grant-reader", "reader-pw")
	require.NoError(t, err)
	g := grant.Read(src, "WBA123")
	require.NotNil(t, g, "grant-reader's publish list and inbox prefix must suffice for a bind and a read")
	assert.Equal(t, []string{"pubsub.WBA123.pressure"}, g.Pub)
	assert.Nil(t, grant.Read(src, "OTHER"))
}

// withUserInfo injects credentials into a nats URL the way the deployment's NATS_URL
// carries the auth-callout-service login.
func withUserInfo(raw, user, pass string) string {
	u, err := url.Parse(raw)
	if err != nil {
		panic(err)
	}
	u.User = url.UserPassword(user, pass)
	return u.String()
}

// The deployment hands the grant reader NATS_URL, which embeds the auth-callout-service
// credentials — account AUTH, which has no JetStream. nats.go lets a URL's userinfo
// override the UserInfo option (connectProto: url.User wins), so without care the grant
// reader authenticates as auth-callout-service and every read fails with "JetStream not
// enabled for account". It must authenticate as grant-reader (account NEXUS) regardless
// of what the URL carries.
func TestTheGrantReaderIgnoresCredentialsEmbeddedInTheURL(t *testing.T) {
	url := startHub(t)
	writer, err := nats.Connect(url, nats.UserInfo("nexus-registry", "registry-pw"))
	require.NoError(t, err)
	defer writer.Close()
	js, err := jetstream.New(writer)
	require.NoError(t, err)
	kv, err := js.CreateKeyValue(context.Background(), jetstream.KeyValueConfig{Bucket: grant.Bucket})
	require.NoError(t, err)
	_, err = kv.Put(context.Background(), "WBA123", []byte(`{"pub":["pubsub.WBA123.pressure"],"sub":[]}`))
	require.NoError(t, err)

	dirty := withUserInfo(url, "auth-callout-service", "callout-pw")
	src, err := grant.NewKV(dirty, "grant-reader", "reader-pw")
	require.NoError(t, err)
	g := grant.Read(src, "WBA123")
	require.NotNil(t, g, "the grant reader must land in NEXUS, not the AUTH account the URL names")
	assert.Equal(t, []string{"pubsub.WBA123.pressure"}, g.Pub)
}

// The registry keeps the services registered with it in a bucket of its own, so they
// survive its restart (spec section 4, "Store"; Plan B ruling 1).
func TestTheRegistryKeepsItsRegistrationsInItsOwnBucket(t *testing.T) {
	url := startHub(t)
	nc, err := nats.Connect(url, nats.UserInfo("nexus-registry", "registry-pw"))
	require.NoError(t, err)
	defer nc.Close()
	js, err := jetstream.New(nc)
	require.NoError(t, err)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	kv, err := js.CreateKeyValue(ctx, jetstream.KeyValueConfig{
		Bucket: "nexus-registry-services", History: 10, Storage: jetstream.FileStorage,
	})
	require.NoError(t, err)
	_, err = kv.Put(ctx, "pressure-monitor", []byte(`{"name":"pressure-monitor","topic":"pressure","pattern":"pubsub","direction":"vehicle-to-cloud"}`))
	require.NoError(t, err, "nexus-registry must be allowed to write its registrations")
	entry, err := kv.Get(ctx, "pressure-monitor")
	require.NoError(t, err)
	assert.Contains(t, string(entry.Value()), `"topic":"pressure"`)
}
