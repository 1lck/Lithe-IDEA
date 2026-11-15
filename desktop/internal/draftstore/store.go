// Package draftstore owns atomic recovery files in application data, never the installation
// or project. Core supplies recovery policy and limits; this adapter performs native I/O.
package draftstore

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

type Entry struct {
	Root     string `json:"root"`
	Path     string `json:"path"`
	Name     string `json:"name"`
	Scratch  bool   `json:"scratch"`
	BaseHash string `json:"baseHash"`
	Text     string `json:"-"`
	Line     int    `json:"line"`
	Column   int    `json:"column"`
}

// All windows in this process serialize native recovery I/O, including quota checks.
// This lock is never acquired by the UI thread.
var recoveryIO sync.Mutex

const maxHeaderBytes = 64 * 1024

type Store struct {
	dir    string
	limits core.EditorRecoveryDecision
}

func New(dir string, limits core.EditorRecoveryDecision) *Store {
	return &Store{dir: filepath.Join(dir, "EditorRecovery"), limits: limits}
}
func Key(path string) string  { sum := sha256.Sum256([]byte(path)); return hex.EncodeToString(sum[:]) }
func Hash(data []byte) string { sum := sha256.Sum256(data); return hex.EncodeToString(sum[:]) }
func (s *Store) filename(root, path string) string {
	return filepath.Join(s.dir, Key(root+"\x00"+path)+".draft")
}
func (s *Store) Load(root, path string) (Entry, bool, error) {
	recoveryIO.Lock()
	defer recoveryIO.Unlock()
	entry, found, err := s.read(s.filename(root, path), true)
	if err == nil && found && (entry.Root != root || entry.Path != path) {
		return Entry{}, false, errors.New("recovery identity does not match")
	}
	return entry, found, err
}
func (s *Store) read(path string, contents bool) (entry Entry, found bool, err error) {
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return entry, false, nil
	}
	if err != nil {
		return entry, false, err
	}
	defer func() { err = errors.Join(err, file.Close()) }()
	reader := bufio.NewReaderSize(file, maxHeaderBytes+1)
	header, err := reader.ReadSlice('\n')
	if err != nil {
		return entry, false, err
	}
	if len(header) > maxHeaderBytes {
		return entry, false, errors.New("recovery metadata exceeds limit")
	}
	if err = json.Unmarshal(header, &entry); err != nil {
		return entry, false, err
	}
	if !contents {
		return entry, true, nil
	}
	data, err := io.ReadAll(io.LimitReader(reader, s.limits.MaxDocumentBytes+1))
	if err != nil {
		return entry, false, err
	}
	if int64(len(data)) > s.limits.MaxDocumentBytes || !utf8.Valid(data) {
		return entry, false, errors.New("recovery source is invalid or exceeds limit")
	}
	entry.Text = string(data)
	return entry, true, nil
}
func (s *Store) files() (entries []os.DirEntry, err error) {
	directory, err := os.Open(s.dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer func() { err = errors.Join(err, directory.Close()) }()
	// A fixed directory bound also limits corrupted/foreign checkpoint inventories.
	files, err := directory.ReadDir(s.limits.MaxDocuments*2 + 1)
	if err != nil && err != io.EOF {
		return nil, err
	}
	if len(files) > s.limits.MaxDocuments*2 {
		return nil, errors.New("recovery directory exceeds limit")
	}
	return files, nil
}
func (s *Store) List(root string, scratch bool) ([]Entry, error) {
	recoveryIO.Lock()
	defer recoveryIO.Unlock()
	files, err := s.files()
	if err != nil {
		return nil, err
	}
	entries := []Entry{}
	for _, file := range files {
		if file.IsDir() || filepath.Ext(file.Name()) != ".draft" {
			continue
		}
		entry, ok, err := s.read(filepath.Join(s.dir, file.Name()), false)
		if err != nil {
			return nil, err
		}
		if ok && entry.Root == root && entry.Scratch == scratch {
			entries = append(entries, entry)
		}
	}
	return entries, nil
}
func (s *Store) Save(entry Entry) error {
	return s.SaveSource(entry, int64(len(entry.Text)), func(w io.Writer) error { _, err := io.Copy(w, strings.NewReader(entry.Text)); return err })
}

// SaveSource streams an immutable native buffer; checkpointing needs no full JSON/text copy.
// The metadata and source commit in one atomic file, so a crash cannot mix generations.
func (s *Store) SaveSource(entry Entry, size int64, write func(io.Writer) error) (err error) {
	recoveryIO.Lock()
	defer recoveryIO.Unlock()
	if size < 0 || size > s.limits.MaxDocumentBytes {
		return errors.New("recovery source exceeds limit")
	}
	header, err := json.Marshal(entry)
	if err != nil {
		return err
	}
	header = append(header, '\n')
	if len(header) > maxHeaderBytes {
		return errors.New("recovery metadata exceeds limit")
	}
	if err := os.MkdirAll(s.dir, 0700); err != nil {
		return err
	}
	files, err := s.files()
	if err != nil {
		return err
	}
	filename := s.filename(entry.Root, entry.Path)
	var total int64
	count := 0
	for _, file := range files {
		if file.IsDir() || filepath.Ext(file.Name()) != ".draft" {
			continue
		}
		count++
		if filepath.Join(s.dir, file.Name()) == filename {
			count--
			continue
		}
		info, err := file.Info()
		if err != nil {
			return err
		}
		total += info.Size()
	}
	if count >= s.limits.MaxDocuments || total+int64(len(header))+size > s.limits.MaxStorageBytes {
		return errors.New("recovery storage is full")
	}
	temp, err := os.CreateTemp(s.dir, ".checkpoint-*")
	if err != nil {
		return err
	}
	temporary := temp.Name()
	defer func() {
		if cleanup := os.Remove(temporary); cleanup != nil && !errors.Is(cleanup, os.ErrNotExist) {
			err = errors.Join(err, cleanup)
		}
	}()
	if _, err = temp.Write(header); err == nil {
		err = write(temp)
	}
	if err == nil {
		err = temp.Sync()
	}
	closeErr := temp.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(temporary, filename)
}
func (s *Store) Remove(root, path string) error {
	recoveryIO.Lock()
	defer recoveryIO.Unlock()
	err := os.Remove(s.filename(root, path))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}
