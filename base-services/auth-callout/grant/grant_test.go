package grant

import (
	"context"
	"errors"
	"testing"

	"github.com/stretchr/testify/assert"
)

type fixed struct {
	g   *Grant
	err error
}

func (f fixed) Grant(context.Context, string) (*Grant, error) { return f.g, f.err }

func TestReadReturnsTheStoredGrant(t *testing.T) {
	g := &Grant{Pub: []string{"pubsub.WBA123.pressure"}}
	assert.Equal(t, g, Read(fixed{g: g}, "WBA123"))
}

func TestReadTreatsAnErrorAsNoGrant(t *testing.T) {
	assert.Nil(t, Read(fixed{err: errors.New("store down")}, "WBA123"), "a broken store narrows, never widens")
}

func TestNoneGrantsNothing(t *testing.T) {
	assert.Nil(t, Read(None{}, "WBA123"))
}

func TestInVinNamespace(t *testing.T) {
	assert.True(t, InVinNamespace("WBA123", "pubsub.WBA123.pressure"))
	assert.True(t, InVinNamespace("WBA123", "pubsub.WBA123.deep.topic"))
	for _, bad := range []string{"pubsub.>", "pubsub.OTHER.pressure", "pubsub.WBA123", "telemetry.WBA123.x", "pubsub.WBA123. x", ">"} {
		assert.False(t, InVinNamespace("WBA123", bad), bad)
	}
}
