// Package passwords hashes local-development passwords with scrypt in a format shared
// with the TypeScript API: scrypt$N$r$p$base64(salt)$base64(key). Production sign-in uses
// OIDC; local passwords exist for development and the demo environment.
package passwords

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"fmt"
	"strconv"
	"strings"

	"golang.org/x/crypto/scrypt"
)

const n, r, p, keyLen = 16384, 8, 1, 32

// Hash returns an encoded scrypt hash.
func Hash(password string) (string, error) {
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	k, err := scrypt.Key([]byte(password), salt, n, r, p, keyLen)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("scrypt$%d$%d$%d$%s$%s", n, r, p, base64.StdEncoding.EncodeToString(salt), base64.StdEncoding.EncodeToString(k)), nil
}

// Verify checks a password against an encoded hash.
func Verify(password, encoded string) bool {
	parts := strings.Split(encoded, "$")
	if len(parts) != 6 || parts[0] != "scrypt" {
		return false
	}
	N, _ := strconv.Atoi(parts[1])
	R, _ := strconv.Atoi(parts[2])
	P, _ := strconv.Atoi(parts[3])
	salt, err1 := base64.StdEncoding.DecodeString(parts[4])
	want, err2 := base64.StdEncoding.DecodeString(parts[5])
	if err1 != nil || err2 != nil || N <= 1 || R <= 0 || P <= 0 {
		return false
	}
	got, err := scrypt.Key([]byte(password), salt, N, R, P, len(want))
	return err == nil && subtle.ConstantTimeCompare(got, want) == 1
}
