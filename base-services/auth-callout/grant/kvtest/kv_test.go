// The grant reader against a real JetStream store: an embedded nats-server, the version
// the hub runs, one per test in a temporary directory.
package kvtest

import (
	"context"
	"net"
	"testing"
	"time"

	"auth-callout/grant"

	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func startJetStream(t *testing.T) string {
	t.Helper()
	opts := &server.Options{Port: -1, JetStream: true, StoreDir: t.TempDir(), NoLog: true, NoSigs: true}
	s, err := server.NewServer(opts)
	require.NoError(t, err)
	go s.Start()
	require.True(t, s.ReadyForConnections(5*time.Second))
	t.Cleanup(s.Shutdown)
	return s.ClientURL()
}

func putGrant(t *testing.T, url, key, value string) {
	t.Helper()
	nc, err := nats.Connect(url)
	require.NoError(t, err)
	defer nc.Close()
	js, err := jetstream.New(nc)
	require.NoError(t, err)
	kv, err := js.CreateKeyValue(context.Background(), jetstream.KeyValueConfig{Bucket: grant.Bucket})
	require.NoError(t, err)
	_, err = kv.Put(context.Background(), key, []byte(value))
	require.NoError(t, err)
}

func TestGrantIsReadFromTheBucket(t *testing.T) {
	url := startJetStream(t)
	putGrant(t, url, "WBA123", `{"pub":["pubsub.WBA123.pressure"],"sub":["pubsub.WBA123.command"]}`)
	src, err := grant.NewKV(url, "", "")
	require.NoError(t, err)
	g := grant.Read(src, "WBA123")
	require.NotNil(t, g)
	assert.Equal(t, []string{"pubsub.WBA123.pressure"}, g.Pub)
	assert.Equal(t, []string{"pubsub.WBA123.command"}, g.Sub)
}

func TestAbsentKeyMeansNoGrant(t *testing.T) {
	url := startJetStream(t)
	putGrant(t, url, "OTHER", `{"pub":[],"sub":[]}`)
	src, err := grant.NewKV(url, "", "")
	require.NoError(t, err)
	assert.Nil(t, grant.Read(src, "WBA123"))
}

func TestGrantKeyIsExact(t *testing.T) {
	url := startJetStream(t)
	putGrant(t, url, "wba123", `{"pub":["pubsub.WBA123.pressure"],"sub":[]}`)
	src, err := grant.NewKV(url, "", "")
	require.NoError(t, err)
	assert.Nil(t, grant.Read(src, "WBA123"), "keys are not normalized; a case mismatch grants nothing")
}

func TestMalformedGrantIsNoGrant(t *testing.T) {
	url := startJetStream(t)
	putGrant(t, url, "WBA123", `not json`)
	src, err := grant.NewKV(url, "", "")
	require.NoError(t, err)
	assert.Nil(t, grant.Read(src, "WBA123"))
}

// The bucket is created by hand (Plan A) or by the registry (Plan B) — possibly after the
// callout started. Until then every read fails closed; from then on it finds the bucket
// without a restart.
func TestBucketCreatedAfterStartIsFoundOnTheNextRead(t *testing.T) {
	url := startJetStream(t)
	src, err := grant.NewKV(url, "", "")
	require.NoError(t, err, "no bucket yet is not an error at start")
	assert.Nil(t, grant.Read(src, "WBA123"), "fails closed while the bucket is absent")
	putGrant(t, url, "WBA123", `{"pub":["pubsub.WBA123.pressure"],"sub":[]}`)
	g := grant.Read(src, "WBA123")
	require.NotNil(t, g, "bound lazily on the next read")
	assert.Equal(t, []string{"pubsub.WBA123.pressure"}, g.Pub)
	assert.Nil(t, grant.Read(grant.None{}, "WBA123"))
}

// startWithUsers starts a JetStream server on a given port (0: any) that knows exactly the
// named users, all with the password "pw".
func startWithUsers(t *testing.T, port int, storeDir string, names ...string) *server.Server {
	t.Helper()
	if port == 0 {
		port = -1
	}
	opts := &server.Options{Port: port, JetStream: true, StoreDir: storeDir, NoLog: true, NoSigs: true}
	for _, n := range names {
		opts.Users = append(opts.Users, &server.User{Username: n, Password: "pw"})
	}
	s, err := server.NewServer(opts)
	require.NoError(t, err)
	go s.Start()
	require.True(t, s.ReadyForConnections(5*time.Second))
	return s
}

// Seen on dan1006 on 2026-10-10: the callout started against a hub that did not know the
// grant reader's user yet. The client library gives up for good after repeated refusals, the
// reader's connection stayed closed, and every vehicle got its control subject only until
// the pod was restarted. The reader must come back by itself once the hub knows it.
func TestReaderRecoversWhenTheHubLearnsItsUserLater(t *testing.T) {
	dir := t.TempDir()
	hub := startWithUsers(t, 0, dir, "admin")
	port := hub.Addr().(*net.TCPAddr).Port
	url := hub.ClientURL()

	src, err := grant.NewKV(url, "grant-reader", "pw")
	require.NoError(t, err)
	// Refused: the reader has no grant to give, and its connection ends.
	require.Never(t, func() bool { return grant.Read(src, "WBA123") != nil }, 3*time.Second, 500*time.Millisecond)

	hub.Shutdown()
	hub.WaitForShutdown()
	hub = startWithUsers(t, port, dir, "admin", "grant-reader")
	t.Cleanup(hub.Shutdown)
	admin, err := nats.Connect(url, nats.UserInfo("admin", "pw"))
	require.NoError(t, err)
	defer admin.Close()
	js, err := jetstream.New(admin)
	require.NoError(t, err)
	kv, err := js.CreateKeyValue(context.Background(), jetstream.KeyValueConfig{Bucket: grant.Bucket})
	require.NoError(t, err)
	_, err = kv.Put(context.Background(), "WBA123", []byte(`{"pub":["pubsub.WBA123.pressure"],"sub":[]}`))
	require.NoError(t, err)

	require.Eventually(t, func() bool { return grant.Read(src, "WBA123") != nil }, 15*time.Second, 500*time.Millisecond,
		"the reader never came back although the hub knows its user now")
}
