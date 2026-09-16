package model

import "testing"

func TestClearKeyHexKidKey(t *testing.T) {
	d := &Drm{Type: "clearkey", Key: "00112233445566778899aabbccddeeff:ffeeddccbbaa99887766554433221100"}
	if !d.DesktopSupported() {
		t.Fatal("expected DesktopSupported")
	}
	got := d.ClearKeyHex()
	want := "ffeeddccbbaa99887766554433221100"
	if got != want {
		t.Fatalf("ClearKeyHex=%q want %q", got, want)
	}
	if err := d.DesktopError(); err != nil {
		t.Fatalf("DesktopError: %v", err)
	}
}

func TestClearKeyHexRejectsHTTP(t *testing.T) {
	d := &Drm{Type: "clearkey", Key: "https://license.example/ck"}
	if d.DesktopSupported() {
		t.Fatal("http license should not be DesktopSupported")
	}
}
