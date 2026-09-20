package spider

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/des"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha1"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"math/big"
	"strings"
)

// aesX Crypto.aes：mode+"Padding" 交给 JCE；短 key/iv 零填充。
// iv == nil 表示 JS null（ECB 场景）；非 nil 则按 CBC 等需 IV 的算法传入。
func aesX(mode string, encrypt bool, input string, inBase64 bool, key string, iv *string, outBase64 bool) string {
	data, ok := decodeCipherInput(input, inBase64)
	if !ok {
		return ""
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
	var ivb []byte
	if iv != nil {
		ivb = padToMin([]byte(*iv), aes.BlockSize)
		if len(ivb) != aes.BlockSize {
			return ""
		}
	}
	return blockCipherX(block, aes.BlockSize, mode, encrypt, data, ivb, outBase64)
}

// desX Crypto.des：DESede（3DES）。两段 key（16B）扩成三段（24B）；CBC IV 8 字节。
func desX(mode string, encrypt bool, input string, inBase64 bool, key string, iv *string, outBase64 bool) string {
	data, ok := decodeCipherInput(input, inBase64)
	if !ok {
		return ""
	}
	keyBuf := desEdeKey([]byte(key))
	if len(keyBuf) != 24 {
		return ""
	}
	block, err := des.NewTripleDESCipher(keyBuf)
	if err != nil {
		return ""
	}
	const blockSize = 8
	var ivb []byte
	if iv != nil {
		ivb = padToMin([]byte(*iv), blockSize)
		if len(ivb) != blockSize {
			return ""
		}
	}
	return blockCipherX(block, blockSize, mode, encrypt, data, ivb, outBase64)
}

func decodeCipherInput(input string, inBase64 bool) ([]byte, bool) {
	if !inBase64 {
		return []byte(input), true
	}
	data, err := decodeJSBase64(input)
	if err != nil {
		return nil, false
	}
	return data, true
}

// blockCipherX：aesX / desX 共用的 CBC/ECB + PKCS7 路径。
func blockCipherX(block cipher.Block, blockSize int, mode string, encrypt bool, data, ivb []byte, outBase64 bool) string {
	upper := strings.ToUpper(mode)
	// Crypto.getAesTransformation / getDesTransformation：CBC/ECB 强制 PKCS5，忽略串内 NoPadding。
	forcePKCS := strings.HasPrefix(upper, "AES/CBC") || strings.HasPrefix(upper, "AES/ECB") ||
		strings.HasPrefix(upper, "DESEDE/CBC") || strings.HasPrefix(upper, "DESEDE/ECB") ||
		strings.HasPrefix(upper, "DES/CBC") || strings.HasPrefix(upper, "DES/ECB")
	noPadding := !forcePKCS && strings.Contains(upper+"PADDING", "NOPADDING")
	useCBC := strings.Contains(upper, "CBC")

	var out []byte
	if useCBC {
		if ivb == nil {
			return ""
		}
		if encrypt {
			if !noPadding {
				data = pkcs7Pad(data, blockSize)
			} else if len(data)%blockSize != 0 {
				return ""
			}
			out = make([]byte, len(data))
			cipher.NewCBCEncrypter(block, ivb).CryptBlocks(out, data)
		} else {
			if len(data) == 0 || len(data)%blockSize != 0 {
				return ""
			}
			out = make([]byte, len(data))
			cipher.NewCBCDecrypter(block, ivb).CryptBlocks(out, data)
			if !noPadding {
				out = pkcs7Unpad(out)
			}
		}
	} else {
		if encrypt {
			if !noPadding {
				data = pkcs7Pad(data, blockSize)
			} else if len(data)%blockSize != 0 {
				return ""
			}
			out = make([]byte, len(data))
			for i := 0; i < len(data); i += blockSize {
				block.Encrypt(out[i:], data[i:])
			}
		} else {
			if len(data) == 0 || len(data)%blockSize != 0 {
				return ""
			}
			out = make([]byte, len(data))
			for i := 0; i < len(data); i += blockSize {
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

// desEdeKey：不足 16 零填；恰 16 时复制前 8 字节扩成 24（两密钥 EDE）。
func desEdeKey(key []byte) []byte {
	const two, three, block = 16, 24, 8
	if len(key) < two {
		padded := make([]byte, two)
		copy(padded, key)
		key = padded
	}
	if len(key) == two {
		expanded := make([]byte, three)
		copy(expanded, key)
		copy(expanded[two:], key[:block])
		return expanded
	}
	if len(key) > three {
		return key[:three]
	}
	if len(key) < three {
		padded := make([]byte, three)
		copy(padded, key)
		return padded
	}
	return key
}

func padToMin(value []byte, minLen int) []byte {
	if len(value) >= minLen {
		return value
	}
	out := make([]byte, minLen)
	copy(out, value)
	return out
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

// rsaX Crypto.rsa（分块：encrypt 块长 keySize-padding，decrypt 块长 keySize）。
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
	noPadding := strings.EqualFold(mode, "RSA/None/NoPadding")
	oaep := strings.EqualFold(mode, "RSA/None/OAEPPadding") ||
		strings.Contains(strings.ToUpper(mode), "OAEP")
	overhead := 11
	if noPadding {
		overhead = 0
	} else if oaep {
		overhead = 42
	}

	var out []byte
	if pub && encrypt {
		k, parseErr := x509.ParsePKIXPublicKey(keyBytes)
		if parseErr != nil {
			return ""
		}
		rpk, ok := k.(*rsa.PublicKey)
		if !ok {
			return ""
		}
		out, err = rsaChunk(encrypt, overhead, rpk.Size(), data, func(chunk []byte) ([]byte, error) {
			if noPadding {
				return rsaRawPublic(rpk, chunk)
			}
			if oaep {
				return rsa.EncryptOAEP(sha1.New(), rand.Reader, rpk, chunk, nil)
			}
			return rsa.EncryptPKCS1v15(rand.Reader, rpk, chunk)
		})
	} else if !pub && !encrypt {
		rpk, parseErr := x509.ParsePKCS8PrivateKey(keyBytes)
		if parseErr != nil {
			return ""
		}
		priv, ok := rpk.(*rsa.PrivateKey)
		if !ok {
			return ""
		}
		out, err = rsaChunk(encrypt, overhead, priv.Size(), data, func(chunk []byte) ([]byte, error) {
			if noPadding {
				return rsaRawPrivate(priv, chunk)
			}
			if oaep {
				return rsa.DecryptOAEP(sha1.New(), rand.Reader, priv, chunk, nil)
			}
			return rsa.DecryptPKCS1v15(rand.Reader, priv, chunk)
		})
	} else if !pub && encrypt {
		rpk, parseErr := x509.ParsePKCS8PrivateKey(keyBytes)
		if parseErr != nil {
			return ""
		}
		priv, ok := rpk.(*rsa.PrivateKey)
		if !ok {
			return ""
		}
		out, err = rsaChunk(encrypt, overhead, priv.Size(), data, func(chunk []byte) ([]byte, error) {
			return rsaRawPrivate(priv, chunk)
		})
	} else if pub && !encrypt {
		k, parseErr := x509.ParsePKIXPublicKey(keyBytes)
		if parseErr != nil {
			return ""
		}
		rpk, ok := k.(*rsa.PublicKey)
		if !ok {
			return ""
		}
		out, err = rsaChunk(encrypt, overhead, rpk.Size(), data, func(chunk []byte) ([]byte, error) {
			return rsaRawPublic(rpk, chunk)
		})
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

func rsaChunk(encrypt bool, overhead, keySize int, data []byte, transform func([]byte) ([]byte, error)) ([]byte, error) {
	if len(data) == 0 {
		return data, nil
	}
	inputBlock := keySize
	if encrypt {
		inputBlock = keySize - overhead
		if inputBlock <= 0 {
			return nil, rsa.ErrMessageTooLong
		}
	}
	var out []byte
	for offset := 0; offset < len(data); offset += inputBlock {
		end := offset + inputBlock
		if end > len(data) {
			end = len(data)
		}
		chunk := data[offset:end]
		if overhead == 0 && encrypt && len(chunk) < keySize {
			padded := make([]byte, keySize)
			copy(padded[keySize-len(chunk):], chunk)
			chunk = padded
		}
		block, err := transform(chunk)
		if err != nil {
			return nil, err
		}
		out = append(out, block...)
	}
	return out, nil
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
