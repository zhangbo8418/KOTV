package spider

import "testing"

func TestParseCatvodProxy_ResOmitsResponseHeaders(t *testing.T) {
	// 对照 FongMi Spider.proxy2：Object 长度 3，Res.headers 只决定 Content-Type。
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
