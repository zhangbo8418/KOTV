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

	// 私钥加密 / 公钥解密（Cipher 双向）。
	encPriv := rsaX("RSA/None/OAEPPadding", false, true, plain, false, string(privPEM), true)
	if encPriv == "" {
		t.Fatal("private encrypt empty")
	}
	decPub := rsaX("RSA/None/OAEPPadding", true, false, encPriv, true, string(pubPEM), false)
	if decPub != plain {
		t.Fatalf("pub decrypt got %q want %q", decPub, plain)
	}
}

func TestRsaXPKCS1PrivateEncryptPublicDecrypt(t *testing.T) {
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

	plain := "kotv-pkcs1-priv"
	enc := rsaX("RSA/ECB/PKCS1Padding", false, true, plain, false, string(privPEM), true)
	if enc == "" {
		t.Fatal("encrypt empty")
	}
	dec := rsaX("RSA/ECB/PKCS1Padding", true, false, enc, true, string(pubPEM), false)
	if dec != plain {
		t.Fatalf("got %q want %q", dec, plain)
	}
}
