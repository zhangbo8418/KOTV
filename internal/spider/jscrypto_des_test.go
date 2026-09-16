package spider

import "testing"

func TestDesXRoundTripCBC(t *testing.T) {
	iv := "12345678"
	plain := "helloDES"
	enc := desX("DESede/CBC", true, plain, false, "0123456789abcdef", &iv, true)
	if enc == "" {
		t.Fatal("encrypt empty")
	}
	dec := desX("DESede/CBC", false, enc, true, "0123456789abcdef", &iv, false)
	if dec != plain {
		t.Fatalf("got %q want %q", dec, plain)
	}
}
