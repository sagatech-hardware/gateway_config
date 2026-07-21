package cups

import (
	"os"
	"path/filepath"
	"strings"
)

// tc.* filenames match the LoRa Basics Station on-disk layout so operators can
// swap in credentials obtained by other means (e.g. a portal download).
const (
	fileURI   = "tc.uri"
	fileTrust = "tc.trust"
	fileCert  = "tc.crt"
	fileKey   = "tc.key"
)

// Save writes the credentials into dir as tc.uri/tc.trust/tc.crt/tc.key (0600).
func (c *Credentials) Save(dir string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	for name, content := range map[string]string{
		fileURI: c.TCURI, fileTrust: c.TCTrust, fileCert: c.TCCert, fileKey: c.TCKey,
	} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o600); err != nil {
			return err
		}
	}
	return nil
}

// LoadCredentials reads tc.* from dir. ok is false (nil error) when the required
// cert/key/uri files are absent, so the caller can fall back to CUPS bootstrap.
func LoadCredentials(dir string) (creds *Credentials, ok bool, err error) {
	uri, err := readIfPresent(filepath.Join(dir, fileURI))
	if err != nil || uri == "" {
		return nil, false, err
	}
	cert, err := readIfPresent(filepath.Join(dir, fileCert))
	if err != nil || cert == "" {
		return nil, false, err
	}
	key, err := readIfPresent(filepath.Join(dir, fileKey))
	if err != nil || key == "" {
		return nil, false, err
	}
	trust, err := readIfPresent(filepath.Join(dir, fileTrust))
	if err != nil {
		return nil, false, err
	}
	return &Credentials{TCURI: strings.TrimSpace(uri), TCTrust: trust, TCCert: cert, TCKey: key}, true, nil
}

func readIfPresent(path string) (string, error) {
	b, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	return string(b), nil
}
