# Third-Party Notices

This project is MIT-licensed (see [LICENSE](LICENSE)). It depends only on the
Dart SDK and the runtime packages below. Every one is under a permissive,
OSI-approved license that is compatible with MIT redistribution — there are no
copyleft or otherwise non-MIT-compatible dependencies.

Dev-only tooling (`test`, `coverage`, `lints`) is not distributed with the
compiled toolchain and is listed at the end for completeness.

## Runtime dependencies

| Package          | Version | License      | Source                                      |
| ---------------- | ------- | ------------ | ------------------------------------------- |
| `analyzer`       | ^14.0.0 | BSD-3-Clause | https://pub.dev/packages/analyzer           |
| `args`           | ^2.6.0  | BSD-3-Clause | https://pub.dev/packages/args               |
| `archive`        | ^4.0.0  | MIT          | https://pub.dev/packages/archive            |
| `crypto`         | ^3.0.0  | BSD-3-Clause | https://pub.dev/packages/crypto             |
| `ed25519_edwards`| ^0.3.1  | MIT          | https://pub.dev/packages/ed25519_edwards    |
| `http`           | ^1.2.0  | BSD-3-Clause | https://pub.dev/packages/http               |
| `path`           | ^1.9.0  | BSD-3-Clause | https://pub.dev/packages/path               |
| `shelf`          | ^1.4.0  | BSD-3-Clause | https://pub.dev/packages/shelf              |
| `shelf_router`   | ^1.1.0  | BSD-3-Clause | https://pub.dev/packages/shelf_router       |

`http` is used only by the Flutter bridge's **opt-in** network capability
(`flutter_bridge/lib/ejenix_flutter_http.dart`); apps that never call
`registerHttp` still link it via the bridge's pubspec, so it is listed as a
runtime dependency.

## Bundled fonts

The control-plane dashboard is set in two typefaces that are **compiled into the
server binary** and served from it (`/brand/inter.woff2`,
`/brand/jetbrains-mono.woff2`). They are embedded rather than fetched so the
page makes no third-party request and renders identically on an air-gapped
deployment.

| Font              | Copyright                        | License      | Source                                        |
| ----------------- | -------------------------------- | ------------ | --------------------------------------------- |
| Inter             | 2016 The Inter Project Authors   | SIL OFL 1.1  | https://github.com/rsms/inter                 |
| JetBrains Mono    | 2020 The JetBrains Mono Authors  | SIL OFL 1.1  | https://github.com/JetBrains/JetBrainsMono    |

Both are latin-subset variable builds covering weights 400–700. The full licence
text is bundled alongside them at [`docs/brand/OFL.txt`](docs/brand/OFL.txt), as
the OFL requires. Neither font is renamed, sold on its own, or otherwise used in
a way the licence restricts.

The Ejenix logo (`docs/brand/ejenix-logo.png`, served at `/brand/logo.png`) is
**not** covered by this project's MIT licence — it is the project's trademark.
Forks may use the software freely but should replace the mark with their own.

The Dart SDK itself is distributed under a BSD-3-Clause license
(https://github.com/dart-lang/sdk/blob/main/LICENSE).

## Dev-only dependencies (not shipped)

| Package    | License      | Source                             |
| ---------- | ------------ | ---------------------------------- |
| `test`     | BSD-3-Clause | https://pub.dev/packages/test      |
| `coverage` | BSD-3-Clause | https://pub.dev/packages/coverage  |

## License texts

The full text of each dependency's license is published in that package's
`LICENSE` file on pub.dev (linked above) and is vendored under `licenses/` in a
tagged release. BSD-3-Clause and MIT both permit redistribution provided their
copyright notice and permission notice are retained, which this file and the
per-package `LICENSE` files satisfy.
