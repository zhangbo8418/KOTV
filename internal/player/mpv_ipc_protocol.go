package player

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
)

// mpvQueryTime 在一条已连接的 MPV IPC 流上查询进度。
// 共用同一个 Reader，避免它预读第二条响应后被丢弃。
func mpvQueryTime(rw io.ReadWriter) (pos, dur float64) {
	reader := bufio.NewReader(rw)
	query := func(prop string) float64 {
		request := fmt.Sprintf(`{"command":["get_property","%s"]}`+"\n", prop)
		if _, err := io.WriteString(rw, request); err != nil {
			return -1
		}
		line, err := reader.ReadBytes('\n')
		if err != nil {
			return -1
		}
		var response struct {
			Data  json.Number `json:"data"`
			Error string      `json:"error"`
		}
		if err := json.Unmarshal(line, &response); err != nil || response.Error != "success" {
			return -1
		}
		value, err := response.Data.Float64()
		if err != nil {
			return -1
		}
		return value
	}

	pos = query("time-pos")
	dur = query("duration")
	if dur < 0 {
		dur = 0
	}
	return pos, dur
}
