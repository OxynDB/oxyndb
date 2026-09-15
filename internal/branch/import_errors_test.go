// SPDX-License-Identifier: AGPL-3.0-or-later

package branch

import (
	"bufio"
	"errors"
	"fmt"
	"strings"
	"testing"
)

func TestPsqlErrorCollector(t *testing.T) {
	c := &psqlErrorCollector{}
	// Chunks split mid-line, as a pipe delivers them.
	for _, chunk := range []string{
		"psql:<stdin>:3: ERR",
		"OR:  relation \"missing_table\" does not exist\nLINE 1: INSERT INTO missing_table VALUES (1);\n",
		"                    ^\nNOTICE:  table \"x\" does not exist, skipping\n",
		"psql:<stdin>:9: ERROR:  syntax error at or near \"CREAT\"",
	} {
		c.Write([]byte(chunk))
	}
	c.flush()
	if c.count != 2 || len(c.first) != 2 {
		t.Fatalf("count=%d first=%q", c.count, c.first)
	}
	if c.first[0] != `psql:<stdin>:3: ERROR:  relation "missing_table" does not exist` {
		t.Errorf("first error = %q", c.first[0])
	}
	err := c.failure("impbad", nil)
	for _, want := range []string{"2 statement(s) failed", `"impbad"`, "missing_table", "CREAT"} {
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("failure() = %v, want it to mention %q", err, want)
		}
	}

	many := &psqlErrorCollector{}
	for i := 0; i < 25; i++ {
		fmt.Fprintf(many, "psql:<stdin>:%d: ERROR:  boom\n", i)
	}
	if many.count != 25 || len(many.first) != psqlErrorsShown {
		t.Fatalf("count=%d kept=%d", many.count, len(many.first))
	}
	if err := many.failure("t", nil); !strings.Contains(err.Error(), "and 5 more") {
		t.Errorf("failure() = %v", err)
	}

	none := &psqlErrorCollector{}
	none.Write([]byte("NOTICE:  nothing to see\n"))
	if none.failure("t", nil) != nil {
		t.Error("no errors, but failure() returned one")
	}
	runErr := errors.New("exit status 2")
	if none.failure("t", runErr) != runErr {
		t.Error("the command's own error was lost")
	}
}

func TestStreamJSONDocs(t *testing.T) {
	read := func(in string, emitErr error) ([]string, error) {
		br := bufio.NewReader(strings.NewReader(in))
		first, err := peekNonSpace(br)
		if err != nil {
			return nil, err
		}
		var docs []string
		err = streamJSONDocs(br, first, func(s string) error {
			docs = append(docs, s)
			return emitErr
		})
		return docs, err
	}
	if docs, err := read(` [ {"a":1}, {"a":"x'y"} ] `, nil); err != nil || len(docs) != 2 || docs[1] != `{"a":"x'y"}` {
		t.Errorf("array: %q %v", docs, err)
	}
	if docs, err := read("{\"a\":1}\n\n  {\"a\":2}  \n", nil); err != nil || len(docs) != 2 {
		t.Errorf("ndjson: %q %v", docs, err)
	}
	if docs, err := read(`[]`, nil); err != nil || len(docs) != 0 {
		t.Errorf("empty array: %q %v", docs, err)
	}
	for in, want := range map[string]string{
		`[{"a":1}, {bad}, {"a":3}]`: "element 2 is not valid JSON",
		`[{"a":1}, `:                "element 2",
		`[{"a":1}`:                  "isn't closed",
		"{\"a\":1}\nnot json\n{}\n": "line 2 is not valid JSON",
	} {
		if _, err := read(in, nil); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("read(%q) = %v, want %q", in, err, want)
		}
	}
	stop := errors.New("pipe closed")
	if _, err := read(`[{"a":1},{"a":2}]`, stop); err != stop {
		t.Errorf("emit error not returned: %v", err)
	}
	if _, err := read("{}\n{}\n", stop); err != stop {
		t.Errorf("emit error not returned (ndjson): %v", err)
	}
}
