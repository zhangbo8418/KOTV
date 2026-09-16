package spider

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha1"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"testing"
)

func TestRsaXOAEPRoundTrip(t *testing.T) {
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	pubDER, err := x509.MarshalPKIXPublicKey(&priv.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	privDER, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		t.Fatal(err)
	}
	pubPEM := pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: pubDER})
	privPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: privDER})

	plain := "kotv-oaep-test"
	enc := rsaX("RSA/None/OAEPPadding", true, true, plain, false, string(pubPEM), true)
	if enc == "" {
		t.Fatal("encrypt empty")
	}
	dec := rsaX("RSA/None/OAEPPadding", false, false, enc, true, string(privPEM), false)
	if dec != plain {
		t.Fatalf("got %q want %q", dec, plain)
	}

	// 与 TV 一致：也接受带 WithSHA-1 的别名。
	raw, _ := base64.StdEncoding.DecodeString(enc)
	out, err := rsa.DecryptOAEP(sha1.New(), rand.Reader, priv, raw, nil)
	if err != nil || string(out) != plain {
		t.Fatalf("stdlib decrypt: %v %q", err, out)
	}
}
