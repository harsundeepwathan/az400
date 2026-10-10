// Package secrets implements envelope encryption for stored credentials.
//
// Each secret is encrypted with a fresh 256-bit data encryption key (DEK) using
// AES-256-GCM, with associated data binding the ciphertext to its owner (for example
// "cloud_account:<org_id>:<account_id>") so a ciphertext copied to another tenant's
// row fails to decrypt. The DEK is wrapped by a key-encryption key (KEK) supplied by a
// KeyProvider. The serialized envelope is JSON so the TypeScript API
// (apps/api/src/lib/envelope.ts) can produce and read the same format.
package secrets

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
)

// Envelope is the serialized form stored in *_ciphertext columns.
type Envelope struct {
	V          int    `json:"v"`
	KeyID      string `json:"kid"`
	WrappedDEK string `json:"wk"` // base64(nonce || AES-GCM(KEK, DEK))
	Nonce      string `json:"n"`  // base64 12-byte nonce for the data
	Ciphertext string `json:"ct"` // base64 AES-GCM(DEK, plaintext, aad)
}

// KeyProvider wraps and unwraps DEKs. Implementations: LocalKeyring (KEK from
// environment, for development and single-node installs) and cloud KMS providers.
type KeyProvider interface {
	ActiveKeyID() string
	Wrap(ctx context.Context, keyID string, dek []byte) ([]byte, error)
	Unwrap(ctx context.Context, keyID string, wrapped []byte) ([]byte, error)
}

// ErrDecrypt is returned for any authentication or format failure.
var ErrDecrypt = errors.New("secret decryption failed")

// Seal encrypts plaintext for the given associated data.
func Seal(ctx context.Context, kp KeyProvider, plaintext []byte, aad string) ([]byte, error) {
	dek := make([]byte, 32)
	if _, err := rand.Read(dek); err != nil {
		return nil, err
	}
	kid := kp.ActiveKeyID()
	wk, err := kp.Wrap(ctx, kid, dek)
	if err != nil {
		return nil, fmt.Errorf("wrap dek: %w", err)
	}
	gcm, err := newGCM(dek)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	ct := gcm.Seal(nil, nonce, plaintext, []byte(aad))
	return json.Marshal(Envelope{
		V: 1, KeyID: kid,
		WrappedDEK: base64.StdEncoding.EncodeToString(wk),
		Nonce:      base64.StdEncoding.EncodeToString(nonce),
		Ciphertext: base64.StdEncoding.EncodeToString(ct),
	})
}

// Open decrypts an envelope produced by Seal (or the TypeScript implementation).
func Open(ctx context.Context, kp KeyProvider, blob []byte, aad string) ([]byte, error) {
	var e Envelope
	if err := json.Unmarshal(blob, &e); err != nil || e.V != 1 {
		return nil, ErrDecrypt
	}
	wk, err1 := base64.StdEncoding.DecodeString(e.WrappedDEK)
	nonce, err2 := base64.StdEncoding.DecodeString(e.Nonce)
	ct, err3 := base64.StdEncoding.DecodeString(e.Ciphertext)
	if err1 != nil || err2 != nil || err3 != nil {
		return nil, ErrDecrypt
	}
	dek, err := kp.Unwrap(ctx, e.KeyID, wk)
	if err != nil {
		return nil, ErrDecrypt
	}
	gcm, err := newGCM(dek)
	if err != nil || len(nonce) != gcm.NonceSize() {
		return nil, ErrDecrypt
	}
	pt, err := gcm.Open(nil, nonce, ct, []byte(aad))
	if err != nil {
		return nil, ErrDecrypt
	}
	return pt, nil
}

func newGCM(key []byte) (cipher.AEAD, error) {
	b, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(b)
}

// LocalKeyring holds KEKs in process memory, loaded from the environment.
//
//	SKYWATCH_KEKS="v2:base64key,v1:base64key"   (first entry is active)
//
// Older keys stay listed until every envelope has been re-wrapped (key rotation).
// Production deployments should use a cloud KMS provider instead (see
// docs/SECURITY.md#key-management).
type LocalKeyring struct {
	active string
	keys   map[string][]byte
}

// NewLocalKeyring parses a keyring spec.
func NewLocalKeyring(spec string) (*LocalKeyring, error) {
	kr := &LocalKeyring{keys: map[string][]byte{}}
	for _, part := range strings.Split(spec, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		id, b64, ok := strings.Cut(part, ":")
		if !ok {
			return nil, fmt.Errorf("keyring entry must be id:base64key")
		}
		k, err := base64.StdEncoding.DecodeString(b64)
		if err != nil || len(k) != 32 {
			return nil, fmt.Errorf("key %q must be 32 bytes base64", id)
		}
		if kr.active == "" {
			kr.active = "local:" + id
		}
		kr.keys["local:"+id] = k
	}
	if kr.active == "" {
		return nil, errors.New("empty keyring")
	}
	return kr, nil
}

// LocalKeyringFromEnv reads SKYWATCH_KEKS.
func LocalKeyringFromEnv() (*LocalKeyring, error) {
	spec := os.Getenv("SKYWATCH_KEKS")
	if spec == "" {
		return nil, errors.New("SKYWATCH_KEKS is not set")
	}
	return NewLocalKeyring(spec)
}

// ActiveKeyID implements KeyProvider.
func (k *LocalKeyring) ActiveKeyID() string { return k.active }

// Wrap implements KeyProvider.
func (k *LocalKeyring) Wrap(_ context.Context, keyID string, dek []byte) ([]byte, error) {
	kek, ok := k.keys[keyID]
	if !ok {
		return nil, fmt.Errorf("unknown key %q", keyID)
	}
	gcm, err := newGCM(kek)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	return gcm.Seal(nonce, nonce, dek, []byte("skywatch-dek")), nil
}

// Unwrap implements KeyProvider.
func (k *LocalKeyring) Unwrap(_ context.Context, keyID string, wrapped []byte) ([]byte, error) {
	kek, ok := k.keys[keyID]
	if !ok {
		return nil, fmt.Errorf("unknown key %q", keyID)
	}
	gcm, err := newGCM(kek)
	if err != nil {
		return nil, err
	}
	if len(wrapped) < gcm.NonceSize() {
		return nil, ErrDecrypt
	}
	return gcm.Open(nil, wrapped[:gcm.NonceSize()], wrapped[gcm.NonceSize():], []byte("skywatch-dek"))
}

// AAD helpers keep the associated-data strings identical across Go and TypeScript.
func CloudAccountAAD(orgID, accountID string) string {
	return "cloud_account:" + orgID + ":" + accountID
}

// ChannelAAD binds notification channel secrets.
func ChannelAAD(orgID, channelID string) string {
	return "notification_channel:" + orgID + ":" + channelID
}
