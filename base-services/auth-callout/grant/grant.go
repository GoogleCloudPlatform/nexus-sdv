// Package grant reads what the Cloud Service Registry has granted a vehicle: the NATS
// subjects it may publish and subscribe on, stored per VIN in a JetStream key-value
// bucket (Increment 2.2). The auth-callout issues exactly this, plus the vehicle's
// control subject, when the vehicle's leaf node connects.
package grant

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"sync"
	"time"

	glog "github.com/labstack/gommon/log"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

// Grant is what the registry stores per VIN, verbatim. Written by the registry (Plan B)
// or by hand (Plan A's mock stage).
type Grant struct {
	Pub []string `json:"pub"`
	Sub []string `json:"sub"`
}

// Source answers "what has the registry granted this VIN?". nil, nil means: nothing
// stored — the vehicle gets its control subject and no more.
type Source interface {
	Grant(ctx context.Context, vin string) (*Grant, error)
}

// Bucket is the key-value bucket the registry writes and the callout reads.
const Bucket = "nexus-registry-grants"

// ReadTimeout bounds every read: a slow store must narrow permissions, never stall a login.
const ReadTimeout = 2 * time.Second

// KV reads grants from the bucket over its own connection: the callout's main connection
// lives in account AUTH and cannot see the store's account. The connection reconnects
// without limit, and the bucket is bound lazily — on the first read, and again after a
// read failed — so a bucket created after the callout started, or a NATS rollout longer
// than a reconnect window, costs reads while it lasts and nothing afterwards.
type KV struct {
	connect func() (*nats.Conn, error)
	mu      sync.Mutex
	nc      *nats.Conn
	js      jetstream.JetStream
	kv      jetstream.KeyValue
}

// withoutUserInfo strips any credentials embedded in a NATS URL. The deployment shares one
// NATS_URL that carries the auth-callout-service login (account AUTH, no JetStream); nats.go
// lets a URL's userinfo override the UserInfo option (connectProto: url.User wins), so the
// grant reader would authenticate as auth-callout-service and every read would fail with
// "JetStream not enabled for account". Removing the userinfo lets the grant user take effect.
// Comma-separated URLs are handled one by one; an unparseable entry is left untouched.
func withoutUserInfo(rawURL string) string {
	parts := strings.Split(rawURL, ",")
	for i, p := range parts {
		u, err := url.Parse(strings.TrimSpace(p))
		if err != nil {
			continue
		}
		u.User = nil
		parts[i] = u.String()
	}
	return strings.Join(parts, ",")
}

// NewKV connects as the grant reader. Only a connection that cannot even be set up is an
// error; an absent bucket is not — every read then fails closed until it exists.
//
// "Set up" does not mean connected: the client keeps trying in the background. It gives up
// for good, though, when the hub refuses its login repeatedly — a hub that does not know the
// reader's user yet, as during an upgrade (dan1006, 2026-10-10) — and leaves the connection
// closed. bucket() therefore opens a new one whenever it finds the old one closed.
func NewKV(rawURL, user, password string) (*KV, error) {
	k := &KV{connect: func() (*nats.Conn, error) {
		return nats.Connect(withoutUserInfo(rawURL),
			nats.UserInfo(user, password),
			nats.Name("auth-callout grant-reader"),
			nats.CustomInboxPrefix("_INBOX_grant_reader"),
			nats.RetryOnFailedConnect(true),
			nats.MaxReconnects(-1),
		)
	}}
	if err := k.reconnect(); err != nil {
		return nil, err
	}
	return k, nil
}

// reconnect replaces the connection. The caller holds k.mu, or nobody else has k yet.
func (k *KV) reconnect() error {
	nc, err := k.connect()
	if err != nil {
		return fmt.Errorf("connect as grant reader: %w", err)
	}
	js, err := jetstream.New(nc)
	if err != nil {
		nc.Close()
		return fmt.Errorf("jetstream: %w", err)
	}
	if k.nc != nil {
		k.nc.Close()
	}
	k.nc, k.js, k.kv = nc, js, nil
	return nil
}

func (k *KV) bucket(ctx context.Context) (jetstream.KeyValue, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	if k.nc.IsClosed() {
		glog.Warn("the grant reader's connection is closed — opening a new one")
		if err := k.reconnect(); err != nil {
			return nil, err
		}
	}
	if k.kv != nil {
		return k.kv, nil
	}
	kv, err := k.js.KeyValue(ctx, Bucket)
	if err != nil {
		return nil, fmt.Errorf("bind bucket %s: %w", Bucket, err)
	}
	k.kv = kv
	glog.Infof("grant reader bound to bucket %s", Bucket)
	return kv, nil
}

func (k *KV) unbind() {
	k.mu.Lock()
	k.kv = nil
	k.mu.Unlock()
}

// Grant returns the stored grant for a VIN; nil, nil when the key is absent. Keys are
// exact — nothing is normalized. A failed read drops the binding so the next one rebinds.
func (k *KV) Grant(ctx context.Context, vin string) (*Grant, error) {
	kv, err := k.bucket(ctx)
	if err != nil {
		return nil, err
	}
	entry, err := kv.Get(ctx, vin)
	if errors.Is(err, jetstream.ErrKeyNotFound) {
		return nil, nil
	}
	if err != nil {
		k.unbind()
		return nil, err
	}
	var g Grant
	if err := json.Unmarshal(entry.Value(), &g); err != nil {
		return nil, fmt.Errorf("grant for %s is not valid JSON: %w", vin, err)
	}
	return &g, nil
}

// None is what the callout runs with when the reader could not be set up: fail closed —
// every vehicle gets its control subject only, never allow-all.
type None struct{}

// Grant of None: nothing, for everyone.
func (None) Grant(context.Context, string) (*Grant, error) { return nil, nil }

// Read fetches the grant with a bound on time. Any failure is logged and treated as
// "nothing granted": a slow or broken store must narrow permissions, never widen them.
func Read(src Source, vin string) *Grant {
	ctx, cancel := context.WithTimeout(context.Background(), ReadTimeout)
	defer cancel()
	g, err := src.Grant(ctx, vin)
	if err != nil {
		glog.Warnf("grant read failed for vin=%s: %v — issuing the control subject only", vin, err)
		return nil
	}
	return g
}

// InVinNamespace keeps a granted subject only under pubsub.<vin>. — the registry may
// decide which of the vehicle's channels are live, never reach past the vehicle.
func InVinNamespace(vin, subject string) bool {
	return strings.HasPrefix(subject, "pubsub."+vin+".") && !strings.ContainsAny(subject, " \t")
}
