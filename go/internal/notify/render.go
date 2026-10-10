package notify

import (
	"fmt"
	"strings"
	"time"
)

type message struct {
	Event, Title, Severity, Status, Summary, Resource, Link string
	Number                                                  int64
	FirstDetected                                           time.Time
	Duration                                                time.Duration
}

func render(p map[string]any, publicURL string) message {
	m := message{}
	m.Event, _ = p["event"].(string)
	inc, _ := p["incident"].(map[string]any)
	m.Title, _ = inc["title"].(string)
	m.Severity, _ = inc["severity"].(string)
	m.Status, _ = inc["status"].(string)
	m.Summary, _ = inc["trigger_summary"].(string)
	if n, ok := inc["number"].(float64); ok {
		m.Number = int64(n)
	}
	if s, ok := inc["first_detected_at"].(string); ok {
		m.FirstDetected, _ = time.Parse(time.RFC3339Nano, s)
	}
	if d, ok := inc["duration_seconds"].(float64); ok {
		m.Duration = time.Duration(d) * time.Second
	}
	if r, ok := inc["resource"].(map[string]any); ok {
		parts := []string{}
		for _, k := range []string{"name", "provider", "region"} {
			if v, _ := r[k].(string); v != "" {
				parts = append(parts, v)
			}
		}
		m.Resource = strings.Join(parts, " · ")
	}
	oneLine := strings.NewReplacer("\r\n", " ", "\r", " ", "\n", " ")
	m.Title, m.Summary, m.Resource = oneLine.Replace(m.Title), oneLine.Replace(m.Summary), oneLine.Replace(m.Resource)
	if id, _ := inc["id"].(string); id != "" && publicURL != "" {
		m.Link = strings.TrimRight(publicURL, "/") + "/incidents/" + id
	}
	return m
}

func (m message) verb() string {
	switch m.Event {
	case "resolved":
		return "RESOLVED"
	case "escalated":
		return "ESCALATED"
	case "repeat":
		return "STILL OPEN"
	case "reopened":
		return "REOPENED"
	case "severity_raised":
		return "SEVERITY RAISED"
	}
	return strings.ToUpper(m.Severity)
}

// Subject is a one-line summary.
func (m message) Subject() string {
	return fmt.Sprintf("[%s] INC-%d %s", m.verb(), m.Number, m.Title)
}

// Text is a plain-text body.
func (m message) Text() string {
	var b strings.Builder
	b.WriteString(m.Subject() + "\n")
	if m.Resource != "" {
		b.WriteString("Resource: " + m.Resource + "\n")
	}
	if m.Summary != "" {
		b.WriteString("Trigger: " + m.Summary + "\n")
	}
	if !m.FirstDetected.IsZero() {
		b.WriteString("First detected: " + m.FirstDetected.UTC().Format("2006-01-02 15:04:05 MST") + "\n")
	}
	if m.Event == "resolved" && m.Duration > 0 {
		b.WriteString("Duration: " + m.Duration.String() + "\n")
	}
	if m.Link != "" {
		b.WriteString(m.Link + "\n")
	}
	return b.String()
}

func slackBody(m message) map[string]any {
	text := fmt.Sprintf("*%s*", escapeSlack(m.Subject()))
	if m.Link != "" {
		text = fmt.Sprintf("*<%s|%s>*", m.Link, escapeSlack(m.Subject()))
	}
	fields := []map[string]any{}
	if m.Resource != "" {
		fields = append(fields, map[string]any{"type": "mrkdwn", "text": "*Resource*\n" + escapeSlack(m.Resource)})
	}
	if !m.FirstDetected.IsZero() {
		fields = append(fields, map[string]any{"type": "mrkdwn", "text": "*First detected*\n" + m.FirstDetected.UTC().Format(time.RFC1123)})
	}
	blocks := []map[string]any{{"type": "section", "text": map[string]any{"type": "mrkdwn", "text": text}}}
	if m.Summary != "" {
		blocks = append(blocks, map[string]any{"type": "section", "text": map[string]any{"type": "mrkdwn", "text": escapeSlack(m.Summary)}})
	}
	if len(fields) > 0 {
		blocks = append(blocks, map[string]any{"type": "section", "fields": fields})
	}
	return map[string]any{"text": m.Subject(), "blocks": blocks}
}

func escapeSlack(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace(s)
}

// teamsBody targets Teams Workflows ("When a Teams webhook request is received"),
// which accepts an Adaptive Card wrapped in a message attachment. Office 365
// connector-based incoming webhooks are retired by Microsoft.
func teamsBody(m message) map[string]any {
	body := []map[string]any{
		{"type": "TextBlock", "text": m.Subject(), "weight": "Bolder", "size": "Medium", "wrap": true},
	}
	facts := []map[string]any{}
	if m.Resource != "" {
		facts = append(facts, map[string]any{"title": "Resource", "value": m.Resource})
	}
	if m.Summary != "" {
		facts = append(facts, map[string]any{"title": "Trigger", "value": m.Summary})
	}
	if !m.FirstDetected.IsZero() {
		facts = append(facts, map[string]any{"title": "First detected", "value": m.FirstDetected.UTC().Format(time.RFC1123)})
	}
	if len(facts) > 0 {
		body = append(body, map[string]any{"type": "FactSet", "facts": facts})
	}
	card := map[string]any{
		"$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
		"type":    "AdaptiveCard", "version": "1.4", "body": body,
	}
	if m.Link != "" {
		card["actions"] = []map[string]any{{"type": "Action.OpenUrl", "title": "Open incident", "url": m.Link}}
	}
	return map[string]any{"type": "message", "attachments": []map[string]any{{
		"contentType": "application/vnd.microsoft.card.adaptive", "content": card,
	}}}
}
