package config

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/hex"
	"testing"
)

func TestDecodeConfigBody_PlainJSONUntouched(t *testing.T) {
	in := ` {"sites":[]} `
	out, err := DecodeConfigBody(in)
	if err != nil || out != in {
		t.Fatalf("out=%q err=%v", out, err)
	}
}

func TestDecodeConfigBody_StarBase64(t *testing.T) {
	plain := `{"sites":[{"key":"a"}]}`
	in := "noise\nAbCd1234**" + base64.StdEncoding.EncodeToString([]byte(plain))
	out, err := DecodeConfigBody(in)
	if err != nil || out != plain {
		t.Fatalf("out=%q err=%v", out, err)
	}
}

func TestDecodeConfigBody_CBCHex(t *testing.T) {
	plain := `{"sites":[{"key":"b"}]}`
	key := "mykey"
	iv := "abcdefghijklm" // 13 字符，右补 0 到 16
	block, err := aes.NewCipher([]byte(padEnd16(key)))
	if err != nil {
		t.Fatal(err)
	}
	pad := block.BlockSize() - len(plain)%block.BlockSize()
	padded := append([]byte(plain), bytes.Repeat([]byte{byte(pad)}, pad)...)
	ct := make([]byte, len(padded))
	cipher.NewCBCEncrypter(block, []byte(padEnd16(iv))).CryptBlocks(ct, padded)
	// 布局：2423($#) + hex(key) + 2324(#$) + hex(ct) + hex(iv)
	in := "2423" + hex.EncodeToString([]byte(key)) + "2324" + hex.EncodeToString(ct) + hex.EncodeToString([]byte(iv))
	// 带空白/换行也要能解。
	in = in[:10] + "\n  " + in[10:]
	out, err := DecodeConfigBody(in)
	if err != nil {
		t.Fatal(err)
	}
	if out != plain {
		t.Fatalf("out=%q", out)
	}
}

func TestDecodeConfigBody_CBCHexBroken(t *testing.T) {
	if _, err := DecodeConfigBody("2423zz"); err == nil {
		t.Fatal("want error")
	}
}

func TestConfigErrorMessage(t *testing.T) {
	if got := ConfigErrorMessage(`{"msg":"账号过期"}`); got != "账号过期" {
		t.Fatalf("got %q", got)
	}
	if got := ConfigErrorMessage(`{"sites":[]}`); got != "" {
		t.Fatalf("got %q", got)
	}
	if got := ConfigErrorMessage(`[1]`); got != "" {
		t.Fatalf("got %q", got)
	}
}
