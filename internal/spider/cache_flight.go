package spider

import "sync"

type cacheFlight struct {
	done chan struct{}
	err  error
}

var cacheFlights sync.Map

func doOnce(key string, fn func() error) error {
	created := &cacheFlight{done: make(chan struct{})}
	actual, loaded := cacheFlights.LoadOrStore(key, created)
	if loaded {
		flight := actual.(*cacheFlight)
		<-flight.done
		return flight.err
	}
	created.err = fn()
	close(created.done)
	cacheFlights.Delete(key)
	return created.err
}
