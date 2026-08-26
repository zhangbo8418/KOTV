// Package lenientjson 把站点/爬虫返回的「脏 JSON」规范化为标准 JSON。
// 对齐 TV：Gson 默认 lenient，容忍单引号、无引号 key、尾逗号、)]}' 前缀等；
// KOTV 用 encoding/json（严格），一处不合法就整包解析失败变空页。
// 这里只做字符级修复，不做语义推断；已合法的输入保持字节不变（快路径）。
package lenientjson

import (
	"bytes"
	"encoding/json"
	"strings"
)

// Sanitize 返回尽量规范化的 JSON 字节；无法修复时原样返回。
func Sanitize(data []byte) []byte {
	data = stripXSSI(data)
	if json.Valid(data) {
		return data
	}
	out, ok := sanitize(bytes.TrimSpace(data), 0)
	if !ok {
		return data
	}
	return out
}

// Unmarshal 先规范化再走 encoding/json。
func Unmarshal(data []byte, v any) error {
	data = bytes.TrimSpace(data)
	if len(data) == 0 {
		data = []byte("null")
	}
	return json.Unmarshal(Sanitize(data), v)
}

// stripXSSI 去掉 )]}' 、/* 注释 等防爬前缀。
func stripXSSI(data []byte) []byte {
	s := strings.TrimLeft(string(bytes.TrimSpace(data)), "\uFEFF \t\r\n")
	if strings.HasPrefix(s, ")]}'") {
		if i := strings.Index(s, "\n"); i >= 0 {
			return []byte(s[i+1:])
		}
	}
	for {
		t := strings.TrimLeft(s, " \t\r\n")
		if !strings.HasPrefix(t, "/*") {
			break
		}
		end := strings.Index(t, "*/")
		if end < 0 {
			break
		}
		s = t[end+2:]
	}
	return []byte(s)
}

type state struct {
	buf   bytes.Buffer
	stack []byte // 未闭合的 { [ 记录
}

func (st *state) last() byte {
	if n := len(st.stack); n > 0 {
		return st.stack[n-1]
	}
	return 0
}

// sanitize 字符级扫描：引号外把单引号换成双引号、给无引号 key/value 补引号、删对象/数组尾逗号。
// value=true 表示当前位置期望一个值（补引号用）；返回 false 表示修复失败。
func sanitize(src []byte, depth int) ([]byte, bool) {
	if depth > 64 {
		return nil, false
	}
	st := &state{}
	i, n := 0, len(src)
	// expectValue: 冒号后 / 容器开始后 / 逗号后 → 下一个 token 是值。
	expectValue := true
	for i < n {
		c := src[i]
		switch c {
		case '"', '\'':
			raw, next, ok := readQuoted(src, i)
			if !ok {
				return nil, false
			}
			st.buf.WriteByte('"')
			st.buf.Write(raw)
			st.buf.WriteByte('"')
			expectValue = false
			i = next
		case '{':
			st.stack = append(st.stack, c)
			st.buf.WriteByte(c)
			expectValue = true
			i++
		case '[':
			st.stack = append(st.stack, c)
			st.buf.WriteByte(c)
			expectValue = true
			i++
		case '}', ']':
			// 尾逗号：} ] 前紧跟逗号 → 删掉。
			trimTrailingComma(&st.buf)
			if n := len(st.stack); n > 0 && st.stack[n-1] == openOf(c) {
				st.stack = st.stack[:n-1]
			}
			st.buf.WriteByte(c)
			expectValue = false
			i++
		case ',':
			st.buf.WriteByte(c)
			expectValue = true
			i++
		case ':':
			st.buf.WriteByte(c)
			expectValue = true
			i++
		default:
			if isSpaceByte(c) {
				// 值位置外的空白保留；值位置留待具体 token 处理。
				if !expectValue {
					st.buf.WriteByte(c)
				}
				i++
				continue
			}
			if c == 't' || c == 'f' || c == 'n' { // true/false/null（必须整词匹配，避免 name/nullish 误伤）
				word, next := readWord(src, i)
				if isJSONLiteral(word) {
					st.buf.Write(word)
					expectValue = false
					i = next
					continue
				}
				// 非字面量：落入下方无引号 token 处理
			}
			if c == '-' || c == '+' || (c >= '0' && c <= '9') || c == '.' {
				word, next := readNumber(src, i)
				st.buf.Write(word)
				expectValue = false
				i = next
				continue
			}
			// 无引号 token：key 或字符串值。Gson lenient 都当字符串收。
			word, next := readUnquoted(src, i)
			if len(word) == 0 {
				return nil, false
			}
			st.buf.WriteByte('"')
			st.buf.Write(escapeJSON(word))
			st.buf.WriteByte('"')
			expectValue = false
			i = next
		}
	}
	if len(st.stack) != 0 {
		return nil, false
	}
	return st.buf.Bytes(), true
}

func openOf(close byte) byte {
	if close == '}' {
		return '{'
	}
	return '['
}

func trimTrailingComma(buf *bytes.Buffer) {
	s := bytes.TrimRight(buf.Bytes(), " \t\r\n")
	if len(s) > 0 && s[len(s)-1] == ',' {
		buf.Truncate(len(s) - 1)
		return
	}
	// 逗号后带空白的情况
	for j := len(s) - 1; j >= 0; j-- {
		if s[j] == ',' {
			buf.Truncate(j)
			return
		}
		if s[j] != ' ' && s[j] != '\t' && s[j] != '\r' && s[j] != '\n' {
			return
		}
	}
}

// readQuoted 从 src[i] 的开引号起读完整字符串，返回内容（不含引号）与下一位置。
// 单引号串内 '' 转义为 '；双引号串按 JSON 转义原样取到结尾。
func readQuoted(src []byte, i int) (content []byte, next int, ok bool) {
	quote := src[i]
	j := i + 1
	var out []byte
	for j < len(src) {
		c := src[j]
		if quote == '"' {
			if c == '\\' {
				if j+1 >= len(src) {
					return nil, 0, false
				}
				out = append(out, c, src[j+1])
				j += 2
				continue
			}
			if c == '"' {
				return out, j + 1, true
			}
			out = append(out, c)
			j++
			continue
		}
		// 单引号：'' 是转义引号；\x 保留转义符交给 JSON 层处理常见 \n \" 等，
		// 但 \' 这类非法转义要还原成字面量，否则双引号包裹后仍非法。
		if c == '\\' && j+1 < len(src) {
			e := src[j+1]
			switch e {
			case '\'', '\\':
				out = append(out, e)
			case 'n':
				out = append(out, '\n')
			case 't':
				out = append(out, '\t')
			case 'r':
				out = append(out, '\r')
			case 'b':
				out = append(out, '\b')
			case 'f':
				out = append(out, '\f')
			case '/':
				out = append(out, '/')
			case 'u':
				if j+6 <= len(src) {
					out = append(out, src[j:j+6]...)
					j += 6
					continue
				}
				out = append(out, e)
			case '"':
				out = append(out, '\\', '"')
			default:
				out = append(out, e)
			}
			j += 2
			continue
		}
		if c == '\'' {
			if j+1 < len(src) && src[j+1] == '\'' {
				out = append(out, '\'')
				j += 2
				continue
			}
			return out, j + 1, true
		}
		out = append(out, c)
		j++
	}
	return nil, 0, false
}

func isSpaceByte(c byte) bool {
	return c == ' ' || c == '\t' || c == '\r' || c == '\n'
}

// readWord 读小写字母串（用于识别 true/false/null）。
func readWord(src []byte, i int) (word []byte, next int) {
	j := i
	for j < len(src) && src[j] >= 'a' && src[j] <= 'z' {
		j++
	}
	return src[i:j], j
}

func isJSONLiteral(word []byte) bool {
	switch string(word) {
	case "true", "false", "null":
		return true
	default:
		return false
	}
}

// readNumber 读数字 token（含 NaN/Infinity 由上层失败兜底）。
func readNumber(src []byte, i int) (word []byte, next int) {
	j := i
	for j < len(src) {
		c := src[j]
		if (c >= '0' && c <= '9') || c == '.' || c == 'e' || c == 'E' ||
			((c == '-' || c == '+') && j > i && (src[j-1] == 'e' || src[j-1] == 'E')) {
			j++
			continue
		}
		break
	}
	return src[i:j], j
}

// readUnquoted 读无引号 key/值：到结构字符（,:}] 或空白）为止。
func readUnquoted(src []byte, i int) (word []byte, next int) {
	j := i
	for j < len(src) {
		c := src[j]
		if c == ',' || c == ':' || c == '}' || c == ']' || c == '"' || c == '\'' ||
			isSpaceByte(c) {
			break
		}
		j++
	}
	return src[i:j], j
}

func escapeJSON(b []byte) []byte {
	if !bytes.ContainsAny(b, "\"\\\n\r\t") {
		return b
	}
	var buf bytes.Buffer
	for _, c := range b {
		switch c {
		case '"':
			buf.WriteString("\\\"")
		case '\\':
			buf.WriteString("\\\\")
		case '\n':
			buf.WriteString("\\n")
		case '\r':
			buf.WriteString("\\r")
		case '\t':
			buf.WriteString("\\t")
		default:
			buf.WriteByte(c)
		}
	}
	return buf.Bytes()
}
