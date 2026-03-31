package output

import (
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"strings"
	"text/tabwriter"
)

func Print(w io.Writer, format string, data any) error {
	switch strings.ToLower(strings.TrimSpace(format)) {
	case "", "table":
		return printTable(w, data)
	case "json":
		return printJSON(w, data)
	default:
		return fmt.Errorf("unsupported output format %q", format)
	}
}

func printJSON(w io.Writer, data any) error {
	bytes, err := json.MarshalIndent(data, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal json output: %w", err)
	}
	_, err = fmt.Fprintln(w, string(bytes))
	return err
}

func printTable(w io.Writer, data any) error {
	raw, err := normalize(data)
	if err != nil {
		return err
	}
	switch v := raw.(type) {
	case []any:
		return printSliceTable(w, v)
	case map[string]any:
		return printMapTable(w, v)
	default:
		_, err := fmt.Fprintln(w, v)
		return err
	}
}

func normalize(data any) (any, error) {
	bytes, err := json.Marshal(data)
	if err != nil {
		return nil, fmt.Errorf("normalize output: %w", err)
	}
	var raw any
	if err := json.Unmarshal(bytes, &raw); err != nil {
		return nil, fmt.Errorf("normalize output: %w", err)
	}
	return raw, nil
}

func printMapTable(w io.Writer, data map[string]any) error {
	tw := tabwriter.NewWriter(w, 0, 0, 2, ' ', 0)
	_, _ = fmt.Fprintln(tw, "KEY\tVALUE")
	keys := make([]string, 0, len(data))
	for key := range data {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		_, _ = fmt.Fprintf(tw, "%s\t%v\n", key, data[key])
	}
	return tw.Flush()
}

func printSliceTable(w io.Writer, rows []any) error {
	if len(rows) == 0 {
		_, err := fmt.Fprintln(w, "No results.")
		return err
	}

	objects := make([]map[string]any, 0, len(rows))
	headers := make(map[string]struct{})
	for _, row := range rows {
		obj, ok := row.(map[string]any)
		if !ok {
			_, err := fmt.Fprintln(w, row)
			return err
		}
		objects = append(objects, obj)
		for key := range obj {
			headers[key] = struct{}{}
		}
	}

	headerList := make([]string, 0, len(headers))
	for key := range headers {
		headerList = append(headerList, key)
	}
	sort.Strings(headerList)

	tw := tabwriter.NewWriter(w, 0, 0, 2, ' ', 0)
	_, _ = fmt.Fprintln(tw, strings.Join(headerList, "\t"))
	for _, row := range objects {
		vals := make([]string, 0, len(headerList))
		for _, key := range headerList {
			vals = append(vals, fmt.Sprintf("%v", row[key]))
		}
		_, _ = fmt.Fprintln(tw, strings.Join(vals, "\t"))
	}
	return tw.Flush()
}
