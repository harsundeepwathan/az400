package secrets

import (
	"context"
	"encoding/base64"
	"errors"
	"strings"
	"testing"
)

const testKey = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=" // 0x00..0x1f

func TestSealOpenRoundTripAndAADBinding(t *testing.T) {
	kr, err := NewLocalKeyring("v1:" + testKey)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	blob, err := Seal(ctx, kr, []byte(`{"client_secret":"s3cr3t"}`), CloudAccountAAD("org-a", "acct-1"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(blob), "s3cr3t") {
		t.Fatal("plaintext leaked into envelope")
	}
	pt, err := Open(ctx, kr, blob, CloudAccountAAD("org-a", "acct-1"))
	if err != nil || string(pt) != `{"client_secret":"s3cr3t"}` {
		t.Fatalf("round trip failed: %v %s", err, pt)
	}
	if _, err := Open(ctx, kr, blob, CloudAccountAAD("org-b", "acct-1")); !errors.Is(err, ErrDecrypt) {
		t.Fatal("ciphertext must not open under another tenant's AAD")
	}
}

func TestKeyRotation(t *testing.T) {
	ctx := context.Background()
	old, _ := NewLocalKeyring("v1:" + testKey)
	blob, _ := Seal(ctx, old, []byte("x"), "aad")
	newKey := base64.StdEncoding.EncodeToString(make([]byte, 32))
	rotated, err := NewLocalKeyring("v2:" + newKey + ",v1:" + testKey)
	if err != nil {
		t.Fatal(err)
	}
	if rotated.ActiveKeyID() != "local:v2" {
		t.Fatalf("active = %s", rotated.ActiveKeyID())
	}
	if pt, err := Open(ctx, rotated, blob, "aad"); err != nil || string(pt) != "x" {
		t.Fatal("old envelopes must open after rotation")
	}
}

// TestCrossLanguageVector decrypts an envelope produced by apps/api/src/lib/envelope.ts
// (see apps/api/test/envelope.test.ts, which decrypts the same vector).
func TestCrossLanguageVector(t *testing.T) {
	kr, _ := NewLocalKeyring("v1:" + testKey)
	pt, err := Open(context.Background(), kr, []byte(crossLanguageVector), "cloud_account:org:acct")
	if err != nil {
		t.Fatalf("TypeScript-produced envelope must open in Go: %v", err)
	}
	if string(pt) != `{"token":"dop_v1_example"}` {
		t.Fatalf("got %s", pt)
	}
}

const crossLanguageVector = `{"v":1,"kid":"local:v1","wk":"ZBPPlqVOdNYF3mc3o2+xgjjnXv+hhIwX/Q/yLUDb3IVQgnK5nw9Vtgy24DGQRx4bXJG8S2c8nQcDCahG","n":"ioBmisasapVK0Yvo","ct":"3kmVX7iTbSIP+0/5cAR7UNS35Q6xH+5uOpUdsqgMMLtt1wXGOwHxHJFu"}`
