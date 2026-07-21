// Package cups implements the LoRa Basics Station CUPS "update-info" client used
// to bootstrap a gateway's LNS (tc.*) credentials — e.g. from ThingPark. A
// Semtech-UDP packet-forwarder gateway runs no Basics Station of its own, so the
// bridge fetches the tc.* material CUPS would hand a real station, then dials the
// LNS itself. ThingPark CUPS is server-auth-only: the registered router id is the
// identity, no client certificate is required.
package cups

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"
)

const updateInfoPath = "/update-info"

// Credentials are the LNS materials a CUPS response provisions, PEM-encoded for
// direct use with crypto/tls.
type Credentials struct {
	TCURI   string
	TCTrust string // PEM CA cert
	TCCert  string // PEM client cert
	TCKey   string // PEM client key
}

// Bootstrap performs POST {cupsURI}/update-info carrying router and returns the
// provisioned tc.* credentials. trustCAPEM validates the CUPS server (empty →
// host system roots). model/station label the request for the CUPS server logs.
func Bootstrap(ctx context.Context, cupsURI, router, model, trustCAPEM string) (*Credentials, error) {
	raw, err := FetchUpdateInfo(ctx, cupsURI, router, model, trustCAPEM)
	if err != nil {
		return nil, err
	}
	return ParseUpdateInfo(raw)
}

// FetchUpdateInfo returns the raw binary CUPS response body.
func FetchUpdateInfo(ctx context.Context, cupsURI, router, model, trustCAPEM string) ([]byte, error) {
	if router == "" {
		return nil, errors.New("router id required")
	}
	tlsCfg, err := clientTLS(trustCAPEM)
	if err != nil {
		return nil, err
	}
	body, err := json.Marshal(map[string]any{
		"router":      router,
		"cupsUri":     cupsURI,
		"tcUri":       "",
		"cupsCredCrc": 0,
		"tcCredCrc":   0,
		"station":     "pktfwd-station-bridge",
		"model":       model,
		"package":     "",
		"keys":        []any{},
	})
	if err != nil {
		return nil, err
	}
	client := &http.Client{
		Timeout:   20 * time.Second,
		Transport: &http.Transport{TLSClientConfig: tlsCfg},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, cupsURI+updateInfoPath, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("POST %s: %w", cupsURI+updateInfoPath, err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("CUPS status %d", resp.StatusCode)
	}
	return raw, nil
}

// ParseUpdateInfo decodes the binary CUPS response. Layout (Basics Station
// cups.c): u8 cupsUriLen+cupsUri, u8 tcUriLen+tcUri, u16le cupsCredLen+cupsCred,
// u16le tcCredLen+tcCred, then signature/update (ignored). The tc credential is
// the DER concatenation trust-cert || client-cert || client-key.
func ParseUpdateInfo(b []byte) (*Credentials, error) {
	r := bytes.NewReader(b)
	cupsURI, err := readU8Str(r)
	if err != nil {
		return nil, fmt.Errorf("cupsUri: %w", err)
	}
	tcURI, err := readU8Str(r)
	if err != nil {
		return nil, fmt.Errorf("tcUri: %w", err)
	}
	if _, err = readU16Blob(r); err != nil {
		return nil, fmt.Errorf("cupsCred: %w", err)
	}
	tcCred, err := readU16Blob(r)
	if err != nil {
		return nil, fmt.Errorf("tcCred: %w", err)
	}
	if len(tcCred) == 0 {
		return nil, fmt.Errorf("CUPS returned no tc credentials (cupsUri=%q tcUri=%q) — router not registered/enabled for BasicStation, or CUPS provisions only on-device", cupsURI, tcURI)
	}
	trust, cert, key, err := splitCred(tcCred)
	if err != nil {
		return nil, fmt.Errorf("split tcCred (%d bytes): %w", len(tcCred), err)
	}
	return &Credentials{TCURI: tcURI, TCTrust: trust, TCCert: cert, TCKey: key}, nil
}

func clientTLS(trustCAPEM string) (*tls.Config, error) {
	cfg := &tls.Config{MinVersion: tls.VersionTLS12}
	if trustCAPEM == "" {
		return cfg, nil // host system roots
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM([]byte(trustCAPEM)) {
		return nil, errors.New("trust CA PEM invalid")
	}
	cfg.RootCAs = pool
	return cfg, nil
}

// splitCred walks the DER concatenation into (trust cert, client cert, key).
func splitCred(blob []byte) (trust, cert, key string, err error) {
	trustDER, rest, err := nextDER(blob)
	if err != nil {
		return "", "", "", fmt.Errorf("trust cert: %w", err)
	}
	certDER, keyDER, err := nextDER(rest)
	if err != nil {
		return "", "", "", fmt.Errorf("client cert: %w", err)
	}
	if len(keyDER) == 0 {
		return "", "", "", errors.New("no private key after client cert (token cred, not mTLS?)")
	}
	keyPEM, err := keyDERtoPEM(keyDER)
	if err != nil {
		return "", "", "", err
	}
	return pemBlock("CERTIFICATE", trustDER), pemBlock("CERTIFICATE", certDER), keyPEM, nil
}

func nextDER(b []byte) (elem, rest []byte, err error) {
	if len(b) < 2 {
		return nil, nil, errors.New("truncated DER header")
	}
	if b[0] != 0x30 {
		return nil, nil, fmt.Errorf("expected DER SEQUENCE 0x30, got 0x%02x", b[0])
	}
	length, hdr := int(b[1]), 2
	if length&0x80 != 0 {
		n := length & 0x7f
		if n == 0 || n > 4 || len(b) < 2+n {
			return nil, nil, fmt.Errorf("bad DER long-form length n=%d", n)
		}
		length = 0
		for i := range n {
			length = length<<8 | int(b[2+i])
		}
		hdr = 2 + n
	}
	end := hdr + length
	if end > len(b) {
		return nil, nil, fmt.Errorf("DER length %d exceeds %d bytes", end, len(b))
	}
	return b[:end], b[end:], nil
}

func keyDERtoPEM(der []byte) (string, error) {
	if k, err := x509.ParsePKCS8PrivateKey(der); err == nil {
		b, err := x509.MarshalPKCS8PrivateKey(k)
		if err != nil {
			return "", err
		}
		return pemBlock("PRIVATE KEY", b), nil
	}
	if k, err := x509.ParsePKCS1PrivateKey(der); err == nil {
		return pemBlock("RSA PRIVATE KEY", x509.MarshalPKCS1PrivateKey(k)), nil
	}
	if k, err := x509.ParseECPrivateKey(der); err == nil {
		b, err := x509.MarshalECPrivateKey(k)
		if err != nil {
			return "", err
		}
		return pemBlock("EC PRIVATE KEY", b), nil
	}
	return "", errors.New("unrecognized tc.key DER (not PKCS8/PKCS1/SEC1)")
}

func pemBlock(typ string, der []byte) string {
	return string(pem.EncodeToMemory(&pem.Block{Type: typ, Bytes: der}))
}

func readU8Str(r *bytes.Reader) (string, error) {
	n, err := r.ReadByte()
	if err != nil {
		return "", err
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return "", err
	}
	return string(buf), nil
}

func readU16Blob(r *bytes.Reader) ([]byte, error) {
	var n uint16
	if err := binary.Read(r, binary.LittleEndian, &n); err != nil {
		return nil, err
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return nil, err
	}
	return buf, nil
}
