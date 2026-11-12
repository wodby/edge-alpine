package backends

import (
	"context"
	"errors"
	"strings"

	"github.com/abtreece/confd/pkg/backends/etcd"
	"github.com/abtreece/confd/pkg/backends/types"
	"github.com/abtreece/confd/pkg/log"
)

// StoreClient is the configuration store contract used by confd templates.
// It matches the upstream interface so the rest of confd builds unchanged.
type StoreClient interface {
	GetValues(ctx context.Context, keys []string) (map[string]string, error)
	WatchPrefix(ctx context.Context, prefix string, keys []string, waitIndex uint64, stopChan chan bool) (uint64, error)
	HealthCheck(ctx context.Context) error
	Close() error
}

// Re-exported like upstream, for the health check code that uses them.
type HealthResult = types.HealthResult
type DetailedHealthChecker = types.DetailedHealthChecker

// New builds the etcd (v3 API) backend used by Wodby Edge. Replacing upstream's
// client.go keeps the other backends, and their dependencies, out of the binary.
func New(config Config) (StoreClient, error) {
	if config.Backend == "" {
		config.Backend = "etcd"
	}
	if config.Backend != "etcd" {
		return nil, errors.New("Wodby Edge confd supports only the etcd backend")
	}

	config.ApplyTimeoutDefaults()

	log.Info("Backend source(s) set to %s", strings.Join(config.BackendNodes, ", "))
	return etcd.NewEtcdClient(
		config.BackendNodes,
		config.ClientCert,
		config.ClientKey,
		config.ClientCaKeys,
		config.ClientInsecure,
		config.BasicAuth,
		config.Username,
		config.Password,
		config.DialTimeout,
	)
}
