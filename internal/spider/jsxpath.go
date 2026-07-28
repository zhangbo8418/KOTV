package spider

import (
	"strings"

	"github.com/antchfx/htmlquery"
	"golang.org/x/net/html"
)

// xpathNodes 对齐 jar Function：parse 以 / 开头时走 xpath。
func xpathNodes(docHTML, expr string) []*html.Node {
	expr = strings.TrimSpace(expr)
	if expr == "" || docHTML == "" {
		return nil
	}
	doc, err := htmlquery.Parse(strings.NewReader(docHTML))
	if err != nil || doc == nil {
		return nil
	}
	nodes, err := htmlquery.QueryAll(doc, expr)
	if err != nil {
		return nil
	}
	return nodes
}

func xpathFirstHTML(docHTML, expr string) string {
	nodes := xpathNodes(docHTML, expr)
	if len(nodes) == 0 {
		return ""
	}
	return htmlquery.OutputHTML(nodes[0], true)
}

func xpathFirstText(docHTML, expr string) string {
	nodes := xpathNodes(docHTML, expr)
	if len(nodes) == 0 {
		return ""
	}
	return strings.TrimSpace(htmlquery.InnerText(nodes[0]))
}

func xpathAllHTML(docHTML, expr string) []string {
	nodes := xpathNodes(docHTML, expr)
	if len(nodes) == 0 {
		return nil
	}
	out := make([]string, 0, len(nodes))
	for _, n := range nodes {
		out = append(out, htmlquery.OutputHTML(n, true))
	}
	return out
}
