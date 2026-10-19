package main

import "net/url"

// redactURL returns the URL without its userinfo. The chart hands the callout a NATS_URL
// with the password embedded, and the DEBUG start-up log used to print it verbatim — into
// Cloud Logging, on every start. A value that does not parse is not echoed either.
func redactURL(raw string) string {
	u, err := url.Parse(raw)
	if err != nil {
		return "(unparseable URL, not shown)"
	}
	u.User = nil
	return u.String()
}
