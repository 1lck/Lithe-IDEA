// This synthetic language server reports which platform's binary was launched.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"runtime"
	"strconv"
	"strings"
)

func main() {
	if err := serve(bufio.NewReader(os.Stdin), os.Stdout); err != nil && err != io.EOF {
		log.Fatal(err)
	}
}

func serve(input *bufio.Reader, output io.Writer) error {
	for {
		body, err := readMessage(input)
		if err != nil {
			return err
		}
		var request struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Params struct {
				TextDocument struct {
					URI string `json:"uri"`
				} `json:"textDocument"`
			} `json:"params"`
		}
		if err := json.Unmarshal(body, &request); err != nil {
			return err
		}
		if request.Method == "exit" {
			return nil
		}
		var response []byte
		switch {
		case request.Method == "initialize":
			response = fmt.Appendf(nil, `{"jsonrpc":"2.0","id":%s,"result":{"capabilities":{"textDocumentSync":1}}}`, request.ID)
		case request.Method == "textDocument/didOpen":
			message := "Packaged language server running on " + runtime.GOOS + "/" + runtime.GOARCH
			if os.Getenv("LITHE_TEST_MANAGED_RUNNER") == "1" {
				message += " via managed runtime"
			}
			response = fmt.Appendf(nil, `{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":%q,"diagnostics":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"severity":1,"message":%q}]}}`,
				request.Params.TextDocument.URI, message)
		case len(request.ID) != 0:
			response = fmt.Appendf(nil, `{"jsonrpc":"2.0","id":%s,"result":null}`, request.ID)
		}
		if len(response) > 0 {
			if _, err := fmt.Fprintf(output, "Content-Length: %d\r\n\r\n%s", len(response), response); err != nil {
				return err
			}
		}
	}
}

func readMessage(input *bufio.Reader) ([]byte, error) {
	var length int
	for {
		line, err := input.ReadString('\n')
		if err != nil {
			return nil, err
		}
		line = strings.TrimSpace(line)
		if line == "" {
			break
		}
		key, value, found := strings.Cut(line, ":")
		if found && strings.EqualFold(key, "Content-Length") {
			length, err = strconv.Atoi(strings.TrimSpace(value))
			if err != nil {
				return nil, err
			}
		}
	}
	if length < 1 || length > 1<<20 {
		return nil, fmt.Errorf("invalid Content-Length %d", length)
	}
	body := make([]byte, length)
	_, err := io.ReadFull(input, body)
	return body, err
}
