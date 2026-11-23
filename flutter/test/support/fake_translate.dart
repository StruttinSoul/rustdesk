/// Mirrors the Rust fallback for an untranslated key: `{value}` becomes value.
String fakeTr(String key) => key.replaceFirstMapped(RegExp(r'\{(.*?)\}'), (m) => m[1]!);
