# MCP Browser

Universal Web Automation Backbone for MCP. Drives headless browsers directly through CDP (Chrome DevTools Protocol) with authenticated sessions, structured search, crawling, and DOM extraction. Implements the 4-Primitive Contract from `mcp_bundle`.

## Components

- **Engine** — direct CDP browser engine implementations.
- **Context** — browser context lifecycle and isolation.
- **Auth profile** — authenticated-session storage and reuse.
- **Search / Download / Extraction templates** — structured operations on top of the engine.
- **Audit** — pluggable audit sinks (file, KV) and audit trail.
- **Policy** — policy engine governing what operations are permitted.
- **Registry** — auth profile store, context registry, engine registry.
- **Browser-specific ports** — `BrowserEnginePort`, `BrowserContextPort`, `BrowserAuthProfilePort`, `BrowserSearchPort`, `BrowserDownloadPort`, `BrowserExtractionTemplatePort`, `BrowserPolicyPort`, `BrowserAuditPort`.

## Quick Start

```dart
import 'package:mcp_browser/mcp_browser.dart';

final engine = await BrowserEngineRegistry.acquire('chrome');
final context = await engine.createContext();
final page = await context.newPage();

await page.navigate(Uri.parse('https://example.com'));
final title = await page.evaluate('document.title');

await context.dispose();
```

## Support

- [Issue Tracker](https://github.com/app-appplayer/mcp_browser/issues)
- [Discussions](https://github.com/app-appplayer/mcp_browser/discussions)

## License

MIT — see [LICENSE](LICENSE).
