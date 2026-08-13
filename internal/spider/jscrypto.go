package spider

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"math/big"
	"strings"
)

// aesX Crypto.aes：mode+"Padding" 交给 JCE；短 key/iv 零填充。
// iv == nil 表示 JS null（ECB 场景）；非 nil 则按 CBC 等需 IV 的算法传入。
func aesX(mode string, encrypt bool, input string, inBase64 bool, key string, iv *string, outBase64 bool) string {
	data := []byte(input)
	if inBase64 {
		var err error
		data, err = decodeJSBase64(input)
		if err != nil {
			return ""
		}
	}
	keyBuf := []byte(key)
	if len(keyBuf) < 16 {
		padded := make([]byte, 16)
		copy(padded, keyBuf)
		keyBuf = padded
	}
	if n := len(keyBuf); n != 16 && n != 24 && n != 32 {
		return ""
	}
	block, err := aes.NewCipher(keyBuf)
	if err != nil {
		return ""
	}

	upper := strings.ToUpper(mode)
	// TV: Cipher.getInstance(mode + "Padding") → …/NoPadding 或 …/PKCS7Padding
	noPadding := strings.Contains(upper+"PADDING", "NOPADDING")
	useCBC := strings.Contains(upper, "CBC")

	var ivb []byte
	if iv != nil {
		ivb = []byte(*iv)
		if len(ivb) < 16 {
			padded := make([]byte, 16)
			copy(padded, ivb)
			ivb = padded
		}
		if len(ivb) != 16 {
			return ""
		}
	}

	var out []byte
	if useCBC {
		if ivb == nil {
			// TV CBC + null IV → Cipher.init 无 IV 失败
			return ""
		}
		if encrypt {
			if !noPadding {
				data = pkcs7Pad(data, aes.BlockSize)
			} else if len(data)%aes.BlockSize != 0 {
				return ""
			}
			out = make([]byte, len(data))
			cipher.NewCBCEncrypter(block, ivb).CryptBlocks(out, data)
		} else {
			if len(data) == 0 || len(data)%aes.BlockSize != 0 {
				return ""
			}
			out = make([]byte, len(data))
			cipher.NewCBCDecrypter(block, ivb).CryptBlocks(out, data)
			if !noPadding {
				out = pkcs7Unpad(out)
			}
		}
	} else {
		// ECB（及 TV 无 IV 初始化路径）：忽略 iv
		if encrypt {
			if !noPadding {
				data = pkcs7Pad(data, aes.BlockSize)
			} else if len(data)%aes.BlockSize != 0 {
				return ""
			}
			out = make([]byte, len(data))
			for i := 0; i < len(data); i += aes.BlockSize {
				block.Encrypt(out[i:], data[i:])
			}
		} else {
			if len(data) == 0 || len(data)%aes.BlockSize != 0 {
				return ""
			}
			out = make([]byte, len(data))
			for i := 0; i < len(data); i += aes.BlockSize {
				block.Decrypt(out[i:], data[i:])
			}
			if !noPadding {
				out = pkcs7Unpad(out)
			}
		}
	}
	if outBase64 {
		return base64Std(out)
	}
	return string(out)
}

func base64Std(data []byte) string {
	return base64.StdEncoding.EncodeToString(data)
}

func decodeJSBase64(text string) ([]byte, error) {
	text = strings.TrimSpace(text)
	// 先把 URL-safe 字符还原再按标准 Base64 解
	normalized := strings.NewReplacer("-", "+", "_", "/").Replace(text)
	if b, err := base64.StdEncoding.DecodeString(normalized); err == nil {
		return b, nil
	}
	if b, err := base64.RawStdEncoding.DecodeString(normalized); err == nil {
		return b, nil
	}
	if b, err := base64.RawURLEncoding.DecodeString(text); err == nil {
		return b, nil
	}
	return base64.URLEncoding.DecodeString(text)
}

// rsaX Crypto.rsa。
// 标准 pub+encrypt / priv+decrypt 走 Go crypto/rsa；
// 反向（priv 加密 / pub 解密）无标准 API，用原始 RSA 模幂尽力对齐（尤其 NoPadding）。
func rsaX(mode string, pub, encrypt bool, input string, inBase64 bool, key string, outBase64 bool) string {
	data := []byte(input)
	if inBase64 {
		var err error
		data, err = decodeJSBase64(input)
		if err != nil {
			return ""
		}
	}
	keyBytes, err := parseRSAKeyBytes(key)
	if err != nil || len(keyBytes) == 0 {
		return ""
	}
	var out []byte
	noPadding := strings.EqualFold(mode, "RSA/None/NoPadding")
	if pub && encrypt {
		k, parseErr := x509.ParsePKIXPublicKey(keyBytes)
		if parseErr != nil {
			return ""
		}
		rpk, ok := k.(*rsa.PublicKey)
		if !ok {
			return ""
		}
		if noPadding {
			out, err = rsaRawPublic(rpk, data)
		} else {
			out, err = rsa.EncryptPKCS1v15(rand.Reader, rpk, data)
		}
	} else if !pub && !encrypt {
		rpk, parseErr := x509.ParsePKCS8PrivateKey(keyBytes)
		if parseErr != nil {
			return ""
		}
		priv, ok := rpk.(*rsa.PrivateKey)
		if !ok {
			return ""
		}
		if noPadding {
			out, err = rsaRawPrivate(priv, data)
		} else {
			out, err = rsa.DecryptPKCS1v15(rand.Reader, priv, data)
		}
	} else if !pub && encrypt {
		// TV 允许私钥加密；Go 标准库无对应 API，NoPadding 用原始模幂，PKCS1 尽力 raw
		rpk, parseErr := x509.ParsePKCS8PrivateKey(keyBytes)
		if parseErr != nil {
			return ""
		}
		priv, ok := rpk.(*rsa.PrivateKey)
		if !ok {
			return ""
		}
		out, err = rsaRawPrivate(priv, data)
	} else if pub && !encrypt {
		k, parseErr := x509.ParsePKIXPublicKey(keyBytes)
		if parseErr != nil {
			return ""
		}
		rpk, ok := k.(*rsa.PublicKey)
		if !ok {
			return ""
		}
		out, err = rsaRawPublic(rpk, data)
	} else {
		return ""
	}
	if err != nil {
		return ""
	}
	if outBase64 {
		return base64Std(out)
	}
	return string(out)
}

// parseRSAKeyBytes Crypto.generateKey：支持 PEM 或剥头后的裸 base64。
func parseRSAKeyBytes(key string) ([]byte, error) {
	key = strings.TrimSpace(key)
	if block, _ := pem.Decode([]byte(key)); block != nil {
		return block.Bytes, nil
	}
	stripped := key
	stripped = strings.ReplaceAll(stripped, "-----BEGIN PUBLIC KEY-----", "")
	stripped = strings.ReplaceAll(stripped, "-----END PUBLIC KEY-----", "")
	stripped = strings.ReplaceAll(stripped, "-----BEGIN PRIVATE KEY-----", "")
	stripped = strings.ReplaceAll(stripped, "-----END PRIVATE KEY-----", "")
	stripped = strings.Map(func(r rune) rune {
		if r == '\r' || r == '\n' || r == ' ' || r == '\t' {
			return -1
		}
		return r
	}, stripped)
	return decodeJSBase64(stripped)
}

func rsaRawPublic(key *rsa.PublicKey, input []byte) ([]byte, error) {
	size := key.Size()
	n := new(big.Int).SetBytes(input)
	if n.Cmp(key.N) >= 0 {
		return nil, rsa.ErrMessageTooLong
	}
	e := big.NewInt(int64(key.E))
	return leftPad(new(big.Int).Exp(n, e, key.N).Bytes(), size), nil
}

func rsaRawPrivate(key *rsa.PrivateKey, input []byte) ([]byte, error) {
	size := key.Size()
	n := new(big.Int).SetBytes(input)
	if n.Cmp(key.N) >= 0 {
		return nil, rsa.ErrDecryption
	}
	return leftPad(new(big.Int).Exp(n, key.D, key.N).Bytes(), size), nil
}

func leftPad(data []byte, size int) []byte {
	out := make([]byte, size)
	copy(out[len(out)-len(data):], data)
	return out
}

func pkcs7Pad(data []byte, blockSize int) []byte {
	pad := blockSize - len(data)%blockSize
	out := make([]byte, len(data)+pad)
	copy(out, data)
	for i := len(data); i < len(out); i++ {
		out[i] = byte(pad)
	}
	return out
}

func pkcs7Unpad(data []byte) []byte {
	if len(data) == 0 {
		return data
	}
	pad := int(data[len(data)-1])
	if pad <= 0 || pad > len(data) {
		return data
	}
	for _, v := range data[len(data)-pad:] {
		if int(v) != pad {
			return data
		}
	}
	return data[:len(data)-pad]
}
