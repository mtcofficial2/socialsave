package server

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"encoding/hex"
	"strings"
)

const chatPasswordIter = 10000

func cleanChatPassword(raw string) (string, error) {
	if len(raw) < 6 || len(raw) > 64 || strings.TrimSpace(raw) == "" {
		return "", chatRejected("Use a password of 6 to 64 characters.")
	}
	return raw, nil
}

func applyChatPassword(user *chatUser, password string) error {
	clean, err := cleanChatPassword(password)
	if err != nil {
		return err
	}
	if user.PasswordHash == "" {
		hashed, err := newPasswordHash(clean)
		if err != nil {
			return err
		}
		user.PasswordHash = hashed
		return nil
	}
	if !passwordMatches(user.PasswordHash, clean) {
		return chatRejected("That password does not match.")
	}
	return nil
}

func newPasswordHash(password string) (string, error) {
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	sum := chatPBKDF2([]byte(password), salt, chatPasswordIter, 32)
	return hex.EncodeToString(salt) + "$" + hex.EncodeToString(sum), nil
}

func passwordMatches(stored, password string) bool {
	saltHex, sumHex, ok := strings.Cut(stored, "$")
	if !ok {
		return false
	}
	salt, err := hex.DecodeString(saltHex)
	if err != nil || len(salt) == 0 {
		return false
	}
	want, err := hex.DecodeString(sumHex)
	if err != nil || len(want) == 0 {
		return false
	}
	got := chatPBKDF2([]byte(password), salt, chatPasswordIter, len(want))
	return subtle.ConstantTimeCompare(got, want) == 1
}

func chatPBKDF2(password, salt []byte, iter, keyLen int) []byte {
	const size = sha256.Size
	blocks := (keyLen + size - 1) / size
	out := make([]byte, 0, blocks*size)
	for i := 1; i <= blocks; i++ {
		out = append(out, chatPBKDF2Block(password, salt, iter, i)...)
	}
	return out[:keyLen]
}

func chatPBKDF2Block(password, salt []byte, iter, index int) []byte {
	mac := hmac.New(sha256.New, password)
	_, _ = mac.Write(salt)
	var idx [4]byte
	binary.BigEndian.PutUint32(idx[:], uint32(index))
	_, _ = mac.Write(idx[:])
	block := mac.Sum(nil)
	out := append([]byte(nil), block...)
	for n := 1; n < iter; n++ {
		mac.Reset()
		_, _ = mac.Write(block)
		block = mac.Sum(nil)
		for i := range out {
			out[i] ^= block[i]
		}
	}
	return out
}
