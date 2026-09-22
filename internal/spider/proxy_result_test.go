package spider

import "testing"

func TestParseCatvodProxy_ResOmitsResponseHeaders(t *testing.T) {
	// Res 对象路径：headers 只用于挑选 Content-Type，不写入 HTTP 响应。
	raw := `{"code":200,"content":"ok","headers":{"Content-Type":"text/plain","X-Extra":"1"}}`
	status, ct, body, headers, err := parseCatvodProxy(raw)
	if err != nil {
		t.Fatal(err)
	}
	if status != 200 || ct != "text/plain" || string(body) != "ok" {
		t.Fatalf("status=%d ct=%q body=%q", status, ct, body)
	}
	if headers != nil {
		t.Fatalf("Res path must not forward headers, got %#v", headers)
	}
}

func TestParseCatvodProxy_ArrayKeepsHeaders(t *testing.T) {
	raw := `[200,"video/mp2t","bytes",{"X-Keep":"yes"}]`
	_, _, _, headers, err := parseCatvodProxy(raw)
	if err != nil {
		t.Fatal(err)
	}
	if headers["X-Keep"] != "yes" {
		t.Fatalf("array path should keep headers, got %#v", headers)
	}
}

func TestParseCatvodProxy_InvalidRejected(t *testing.T) {
	for _, raw := range []string{"", "null", "[]", "{}", "oops"} {
		_, _, _, _, err := parseCatvodProxy(raw)
		if err == nil {
			t.Fatalf("want error for %q", raw)
		}
	}
}
