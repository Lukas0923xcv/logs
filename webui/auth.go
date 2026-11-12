package main

import (
	"bufio"
	"crypto/sha256"
	"fmt"
	"net/http"
	"os"
	"strings"
	"sync"

	"golang.org/x/crypto/bcrypt"
)

// basicAuth checks requests against an htpasswd file with bcrypt hashes
// (create one with: htpasswd -nB <user>). Plain-text or other hash formats
// are rejected at startup, so a password never has to be stored readable.
type basicAuth struct {
	users map[string][]byte
	dummy []byte // hash checked for unknown users, so both cases take equally long
	mu    sync.Mutex
	ok    map[[32]byte]bool // digests of credentials that already passed bcrypt
}

func loadBasicAuth(file string) (*basicAuth, error) {
	f, err := os.Open(file)
	if err != nil {
		return nil, fmt.Errorf("basic auth file: %w", err)
	}
	defer f.Close()
	ba := &basicAuth{users: map[string][]byte{}, ok: map[[32]byte]bool{}}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		user, hash, found := strings.Cut(line, ":")
		if !found || user == "" || !strings.HasPrefix(hash, "$2") {
			return nil, fmt.Errorf("basic auth file %s: every line must be user:bcrypt-hash", file)
		}
		ba.users[user] = []byte(hash)
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("basic auth file: %w", err)
	}
	if len(ba.users) == 0 {
		return nil, fmt.Errorf("basic auth file %s contains no users; refusing to start without auth", file)
	}
	ba.dummy, _ = bcrypt.GenerateFromPassword([]byte("unused"), bcrypt.DefaultCost)
	return ba, nil
}

func (ba *basicAuth) check(r *http.Request) bool {
	user, pass, ok := r.BasicAuth()
	if !ok {
		return false
	}
	digest := sha256.Sum256([]byte(user + "\x00" + pass))
	ba.mu.Lock()
	cached := ba.ok[digest]
	ba.mu.Unlock()
	if cached {
		return true
	}
	hash, known := ba.users[user]
	if !known {
		// Spend the same time as for a known user.
		_ = bcrypt.CompareHashAndPassword(ba.dummy, []byte(pass))
		return false
	}
	if bcrypt.CompareHashAndPassword(hash, []byte(pass)) != nil {
		return false
	}
	ba.mu.Lock()
	if len(ba.ok) > 64 {
		ba.ok = map[[32]byte]bool{}
	}
	ba.ok[digest] = true
	ba.mu.Unlock()
	return true
}
