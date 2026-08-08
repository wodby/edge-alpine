package backends

import (
	"errors"

	"github.com/kelseyhightower/confd/backends/etcdv3"
	"github.com/kelseyhightower/confd/log"
)

// StoreClient is the configuration store contract used by confd templates.
type StoreClient interface {
	GetValues(keys []string) (map[string]string, error)
	WatchPrefix(prefix string, keys []string, waitIndex uint64, stopChan chan bool) (uint64, error)
}

// New builds the etcd v3-only backend used by Wodby Edge.
func New(config Config) (StoreClient, error) {
	if config.Backend != "etcd" && config.Backend != "etcdv3" {
		return nil, errors.New("Wodby Edge confd supports only the etcdv3 backend")
	}

	log.Info("Backend source(s) configured for etcdv3")
	return etcdv3.NewEtcdClient(
		config.BackendNodes,
		config.ClientCert,
		config.ClientKey,
		config.ClientCaKeys,
		config.BasicAuth,
		config.Username,
		config.Password,
	)
}
