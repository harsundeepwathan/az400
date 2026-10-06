# Legal pages

`privacy.html` and `terms.html` are self-contained static pages (inline CSS, no scripts, fonts or images, light and dark mode). They are **drafts that need legal review**: fill in every `[placeholder]` in `docs/legal/*.md` first, then rebuild.

## Edit and rebuild

The Markdown in `docs/legal/` is the source. After editing it:

```sh
python3 web/legal/build.py   # standard library only; rewrites privacy.html and terms.html
```

The "Implementation references" checklist at the end of `privacy.md` stays internal and is not published.

## Host

Any static host on HTTPS works (GitHub Pages, Netlify, Cloudflare Pages, S3 + CloudFront, or the same domain as the API). Upload both files to the same folder so the footer links between them work, for example:

- `https://[your-domain]/legal/privacy.html`
- `https://[your-domain]/legal/terms.html`

The pages carry `noindex` while they are drafts. Remove that meta tag in `build.py` once they're approved.

## Wire into the app

Set the two Info.plist keys in `project.yml` (target `Vector`, `info.properties`), then run `xcodegen`:

```yaml
VectorTermsURL: "https://[your-domain]/legal/terms.html"
VectorPrivacyURL: "https://[your-domain]/legal/privacy.html"
```

`App/Vector/App/AppConfig.swift` reads them. If they are empty, the app falls back to Apple's standard EULA and Apple's privacy page, which is not acceptable for release.

Also put the same URLs in App Store Connect: the **Privacy Policy URL** under App Privacy, and the Terms of Use (EULA) link in the app description or as a custom EULA. App Review requires both for auto-renewing subscriptions.
