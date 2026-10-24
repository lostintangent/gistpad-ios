# GistPadPlatform

Native system entry points share `NotebookRoute`. The router accepts the web's
hash routes and equivalent HTTPS paths, plus `gistpad://` routes for widgets,
Shortcuts and Spotlight. Share links preserve the exact selected filename.
The authentication callback is deliberately excluded and remains owned by Auth.
Unknown hosts, credential-bearing URLs and malformed routes are rejected.

The main app consumes routes through its existing navigation and document-session
handoff. Receiving a link never publishes a note. New-note and Today routes use
the same explicit local staging actions as the Library.

Universal links require the associated-domains entitlement and deployment of
`public/.well-known/apple-app-site-association` from the web repository. Until that
file is deployed, native scheme links work but HTTPS links are not claimed to
open the app.
