package security

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/appcoreos/appcorectl/internal/config"
)

// LocalClientPKI contains generated paths for a local client CA and client cert.
type LocalClientPKI struct {
	TargetDir      string
	CACertPath     string
	CAKeyPath      string
	ClientCertPath string
	ClientKeyPath  string
	CACertPEM      []byte
}

func LocalPKITargetDir(targetName string) (string, error) {
	root, err := config.DefaultPKIRootDir()
	if err != nil {
		return "", fmt.Errorf("resolve PKI root directory: %w", err)
	}
	return filepath.Join(root, sanitizeTarget(targetName)), nil
}

func EnsureLocalClientPKI(targetName string) (*LocalClientPKI, error) {
	targetDir, err := LocalPKITargetDir(targetName)
	if err != nil {
		return nil, err
	}
	pki := &LocalClientPKI{
		TargetDir:      targetDir,
		CACertPath:     filepath.Join(targetDir, "client-ca.pem"),
		CAKeyPath:      filepath.Join(targetDir, "client-ca.key"),
		ClientCertPath: filepath.Join(targetDir, "client.crt"),
		ClientKeyPath:  filepath.Join(targetDir, "client.key"),
	}

	if allExist(pki.CACertPath, pki.CAKeyPath, pki.ClientCertPath, pki.ClientKeyPath) {
		caPEM, err := os.ReadFile(pki.CACertPath)
		if err != nil {
			return nil, fmt.Errorf("read local client CA certificate: %w", err)
		}
		pki.CACertPEM = caPEM
		return pki, nil
	}
	if anyExist(pki.CACertPath, pki.CAKeyPath, pki.ClientCertPath, pki.ClientKeyPath) {
		return nil, errors.New("partial local PKI state detected; remove the target PKI directory and retry")
	}
	if err := os.MkdirAll(targetDir, 0o700); err != nil {
		return nil, fmt.Errorf("create target PKI directory: %w", err)
	}

	caCertPEM, caKeyPEM, caCert, caKey, err := generateCA()
	if err != nil {
		return nil, err
	}
	clientCertPEM, clientKeyPEM, err := generateClientCert(caCert, caKey)
	if err != nil {
		return nil, err
	}

	if err := os.WriteFile(pki.CACertPath, caCertPEM, 0o600); err != nil {
		return nil, fmt.Errorf("write client CA certificate: %w", err)
	}
	if err := os.WriteFile(pki.CAKeyPath, caKeyPEM, 0o600); err != nil {
		return nil, fmt.Errorf("write client CA key: %w", err)
	}
	if err := os.WriteFile(pki.ClientCertPath, clientCertPEM, 0o600); err != nil {
		return nil, fmt.Errorf("write client certificate: %w", err)
	}
	if err := os.WriteFile(pki.ClientKeyPath, clientKeyPEM, 0o600); err != nil {
		return nil, fmt.Errorf("write client key: %w", err)
	}

	pki.CACertPEM = caCertPEM
	return pki, nil
}

func sanitizeTarget(name string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		return "default"
	}
	out := strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z':
			return r
		case r >= 'A' && r <= 'Z':
			return r
		case r >= '0' && r <= '9':
			return r
		case r == '-', r == '_', r == '.':
			return r
		default:
			return '-'
		}
	}, name)
	return strings.Trim(out, "-")
}

func anyExist(paths ...string) bool {
	for _, path := range paths {
		if _, err := os.Stat(path); err == nil {
			return true
		}
	}
	return false
}

func allExist(paths ...string) bool {
	for _, path := range paths {
		if _, err := os.Stat(path); err != nil {
			return false
		}
	}
	return true
}

func generateCA() ([]byte, []byte, *x509.Certificate, *ecdsa.PrivateKey, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, nil, nil, fmt.Errorf("generate client CA key: %w", err)
	}
	serial, err := rand.Int(rand.Reader, big.NewInt(1<<62))
	if err != nil {
		return nil, nil, nil, nil, fmt.Errorf("generate client CA serial: %w", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "appcorectl-local-client-ca"},
		NotBefore:             time.Now().Add(-1 * time.Hour),
		NotAfter:              time.Now().Add(10 * 365 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign | x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return nil, nil, nil, nil, fmt.Errorf("create client CA certificate: %w", err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, nil, nil, nil, fmt.Errorf("parse generated client CA certificate: %w", err)
	}
	privateDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, nil, nil, nil, fmt.Errorf("marshal client CA private key: %w", err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: privateDER})
	return certPEM, keyPEM, cert, key, nil
}

func generateClientCert(caCert *x509.Certificate, caKey *ecdsa.PrivateKey) ([]byte, []byte, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, fmt.Errorf("generate client key: %w", err)
	}
	serial, err := rand.Int(rand.Reader, big.NewInt(1<<62))
	if err != nil {
		return nil, nil, fmt.Errorf("generate client serial: %w", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: "appcorectl-local-client"},
		NotBefore:    time.Now().Add(-1 * time.Hour),
		NotAfter:     time.Now().Add(2 * 365 * 24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, caCert, &key.PublicKey, caKey)
	if err != nil {
		return nil, nil, fmt.Errorf("create client certificate: %w", err)
	}
	privateDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, nil, fmt.Errorf("marshal client private key: %w", err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: privateDER})
	return certPEM, keyPEM, nil
}
