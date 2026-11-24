#!/usr/bin/env python3
"""Private RAG demo (Python standard library only - the host has no internet egress).

Flow: question -> Azure AI Search (private endpoint, Entra token) -> top-k documents
      -> Foundry model via the OpenAI v1 Responses API (private endpoint, Entra token)
      -> grounded answer with source ids.

All credentials come from the VM's managed identity via IMDS. No keys, no secrets.
Configuration (environment variables, set by the systemd unit):
  SEARCH_ENDPOINT, SEARCH_INDEX, OPENAI_ENDPOINT, MODEL_DEPLOYMENT,
  APP_PORT (default 8443), TLS_CERT, TLS_KEY, TOP_K (default 3)
"""
import html
import json
import os
import re
import ssl
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SEARCH_ENDPOINT = os.environ["SEARCH_ENDPOINT"].rstrip("/")
SEARCH_INDEX = os.environ["SEARCH_INDEX"]
OPENAI_ENDPOINT = os.environ["OPENAI_ENDPOINT"].rstrip("/")
MODEL_DEPLOYMENT = os.environ["MODEL_DEPLOYMENT"]
APP_PORT = int(os.environ.get("APP_PORT", "8443"))
TOP_K = int(os.environ.get("TOP_K", "3"))
SEARCH_API_VERSION = "2024-07-01"
MAX_QUESTION = 1000

SYSTEM_PROMPT = (
    "You answer questions about Contoso internal policies. Use ONLY the numbered sources "
    "provided. Cite source ids in square brackets, e.g. [pol-003]. If the sources do not "
    "contain the answer, say you don't know. Be concise."
)

_token_cache = {}
_token_lock = threading.Lock()


def get_token(resource):
    """Managed identity token from IMDS, cached until 5 minutes before expiry."""
    with _token_lock:
        cached = _token_cache.get(resource)
        if cached and cached[1] - 300 > time.time():
            return cached[0]
        url = ("http://169.254.169.254/metadata/identity/oauth2/token"
               f"?api-version=2018-02-01&resource={resource}")
        req = urllib.request.Request(url, headers={"Metadata": "true"})
        with urllib.request.urlopen(req, timeout=10) as r:
            body = json.load(r)
        _token_cache[resource] = (body["access_token"], int(body["expires_on"]))
        return body["access_token"]


def post_json(url, payload, resource, timeout=60):
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(), method="POST",
        headers={"Authorization": f"Bearer {get_token(resource)}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def retrieve(question):
    url = f"{SEARCH_ENDPOINT}/indexes/{SEARCH_INDEX}/docs/search?api-version={SEARCH_API_VERSION}"
    body = post_json(url, {"search": question, "top": TOP_K, "select": "id,title,content"},
                     "https://search.azure.com")
    return body.get("value", [])


def generate(question, docs):
    sources = "\n\n".join(f"[{d['id']}] {d['title']}\n{d['content']}" for d in docs) or "(no sources found)"
    payload = {
        "model": MODEL_DEPLOYMENT,
        "instructions": SYSTEM_PROMPT,
        "input": f"Sources:\n{sources}\n\nQuestion: {question}",
    }
    body = post_json(f"{OPENAI_ENDPOINT}/openai/v1/responses", payload, "https://cognitiveservices.azure.com")
    if body.get("output_text"):
        return body["output_text"]
    parts = [c.get("text", "") for o in body.get("output", []) if o.get("type") == "message"
             for c in o.get("content", []) if c.get("type") == "output_text"]
    return "".join(parts)


def ask(question):
    docs = retrieve(question)
    answer = generate(question, docs)
    return {"answer": answer,
            "sources": [{"id": d["id"], "title": d["title"], "score": d.get("@search.score"),
                         "url": f"/docs/{d['id']}"} for d in docs]}


DOC_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")


def get_document(doc_id):
    """Fetch one document by key from the private index (read-only, VM managed identity)."""
    url = (f"{SEARCH_ENDPOINT}/indexes/{SEARCH_INDEX}/docs/{urllib.parse.quote(doc_id)}"
           f"?api-version={SEARCH_API_VERSION}&$select=id,title,category,content")
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {get_token('https://search.azure.com')}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise


DOC_PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>{title}</title>
<style>body{{font-family:Segoe UI,sans-serif;max-width:820px;margin:2em auto}}.meta{{color:#555}}
.doc{{white-space:pre-wrap;background:#f3f6fa;padding:1em}}</style></head>
<body><p class="meta"><a href="/">&larr; Contoso policy assistant</a></p><h2>{title}</h2>
<p class="meta">Document <code>{id}</code> &middot; {category} &middot; source: private knowledge index (synthetic demo data)</p>
<div class="doc">{content}</div></body></html>"""


PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>Private RAG demo</title>
<style>body{font-family:Segoe UI,sans-serif;max-width:820px;margin:2em auto}textarea{width:100%}
.src{color:#555;font-size:.9em}.ans{white-space:pre-wrap;background:#f3f6fa;padding:1em}</style></head>
<body><h2>Contoso policy assistant (private RAG demo)</h2>
<p class="src">AI Search + Foundry model over private endpoints, Entra managed identity, no internet egress.</p>
<form method="post" action="/"><textarea name="q" rows="3" maxlength="1000">{q}</textarea>
<p><button type="submit">Ask</button></p></form>{result}</body></html>"""


class Handler(BaseHTTPRequestHandler):
    server_version = "rag-demo"
    sys_version = ""

    def log_message(self, fmt, *args):  # no prompt content in logs
        sys.stderr.write("%s %s\n" % (self.command, self.path.split("?")[0]))

    def _send(self, code, body, ctype):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _read_body(self):
        length = min(int(self.headers.get("Content-Length") or 0), 16384)
        return self.rfile.read(length).decode("utf-8", "replace")

    def do_GET(self):
        if self.path == "/healthz":
            return self._send(200, json.dumps({"status": "ok"}), "application/json")
        if self.path in ("/", "/index.html"):
            return self._send(200, PAGE.replace("{q}", "").replace("{result}", ""), "text/html; charset=utf-8")
        if self.path.startswith("/docs/"):
            doc_id = self.path[len("/docs/"):].split("?")[0]
            if not DOC_ID_RE.match(doc_id):
                return self._send(400, "invalid document id", "text/plain")
            try:
                d = get_document(doc_id)
            except urllib.error.HTTPError as e:
                return self._send(502, json.dumps({"error": f"upstream {e.code}"}), "application/json")
            if not d:
                return self._send(404, "document not found", "text/plain")
            page = DOC_PAGE.format(**{k: html.escape(str(d.get(k, ""))) for k in ("id", "title", "category", "content")})
            return self._send(200, page, "text/html; charset=utf-8")
        self._send(404, "not found", "text/plain")

    def do_POST(self):
        try:
            if self.path == "/api/ask":
                q = str(json.loads(self._read_body() or "{}").get("question", "")).strip()[:MAX_QUESTION]
                if not q:
                    return self._send(400, json.dumps({"error": "question is required"}), "application/json")
                return self._send(200, json.dumps(ask(q)), "application/json")
            if self.path == "/":
                from urllib.parse import parse_qs
                q = parse_qs(self._read_body()).get("q", [""])[0].strip()[:MAX_QUESTION]
                result = ""
                if q:
                    r = ask(q)
                    srcs = ", ".join(f'<a href="{html.escape(s["url"])}">{html.escape(s["id"])}</a> ({html.escape(s["title"])})' for s in r["sources"])
                    result = f'<div class="ans">{html.escape(r["answer"])}</div><p class="src">Sources: {srcs}</p>'
                return self._send(200, PAGE.replace("{q}", html.escape(q)).replace("{result}", result),
                                  "text/html; charset=utf-8")
            self._send(404, "not found", "text/plain")
        except urllib.error.HTTPError as e:
            # Surface the upstream status (e.g. 403 = RBAC/network) without leaking tokens.
            self._send(502, json.dumps({"error": f"upstream {e.code}", "url": e.url.split("?")[0]}), "application/json")
        except Exception as e:  # noqa: BLE001
            self._send(500, json.dumps({"error": type(e).__name__}), "application/json")


def main():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(os.environ["TLS_CERT"], os.environ["TLS_KEY"])
    httpd = ThreadingHTTPServer(("0.0.0.0", APP_PORT), Handler)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    print(f"rag-demo listening on :{APP_PORT}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
