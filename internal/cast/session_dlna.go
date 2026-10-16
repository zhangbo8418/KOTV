package cast

import "github.com/bobo/KOTV/internal/dlna"

func ConnectDLNA(location string) (dlna.Device, error) {
	return dlna.ConnectByLocation(location)
}

func StopDLNA(d dlna.Device) error {
	return dlna.Stop(d)
}

func ProbeDLNA(d dlna.Device) (bool, string, error) {
	return dlna.TransportActive(d)
}
