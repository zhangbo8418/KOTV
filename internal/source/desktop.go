//go:build !android

package source

import (
	"encoding/json"
	"fmt"
)

func fetchPlatform(playURL string, _ json.RawMessage) (string, error) {
	return "", fmt.Errorf("荐片/TVBus 仅安卓支持: %s", playURL)
}

func stopPlatform() {}
