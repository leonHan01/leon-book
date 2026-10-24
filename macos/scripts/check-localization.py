#!/usr/bin/env python3
"""Check catalogs and application-owned UI keys without launching the app."""
from collections import Counter
from html.parser import HTMLParser
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / 'Sources/LeonBook/Resources'
HAN = re.compile(r'[\u3400-\u9fff]')
PAIR = re.compile(r'"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;')
FORMAT = re.compile(r'%%|%(?:\d+\$)?(?:ll|l)?[@diufgs]')
errors = []
pairs = [(json.loads('"' + k + '"'), json.loads('"' + v + '"'))
         for k, v in PAIR.findall((RESOURCES / 'en.lproj/Localizable.strings').read_text())]
catalog = dict(pairs)
for key, count in Counter(k for k, _ in pairs).items():
    if count != 1:
        errors.append(f'Duplicate English key: {key!r}')

def formats(value):
    return Counter(re.sub(r'^%\d+\$', '%', token)
                   for token in FORMAT.findall(value) if token != '%%')

for key, value in pairs:
    if HAN.search(value):
        errors.append(f'Chinese in English translation: {key!r}')
    if formats(key) != formats(value):
        errors.append(f'Format mismatch: {key!r} -> {value!r}')

def end_expression(source, pos):
    depth = 1
    while depth:
        if source[pos] == '"':
            pos = end_string(source, pos)
            continue
        if source[pos] == '(':
            depth += 1
        if source[pos] == ')':
            depth -= 1
        pos += 1
    return pos

def end_string(source, pos):
    delimiter = '"""' if source.startswith('"""', pos) else '"'
    pos += len(delimiter)
    while pos < len(source):
        if source.startswith(delimiter, pos):
            return pos + len(delimiter)
        if source.startswith('\\(', pos):
            pos = end_expression(source, pos + 2)
        elif source[pos] == '\\':
            pos += 2
        else:
            pos += 1
    raise ValueError('Unterminated Swift string')

def literals(source):
    pos = 0
    while pos < len(source):
        if source.startswith('//', pos):
            end = source.find('\n', pos)
            pos = end if end >= 0 else len(source)
        elif source.startswith('/*', pos):
            end = source.find('*/', pos + 2)
            pos = end + 2 if end >= 0 else len(source)
        elif source.startswith('#"', pos):
            end = source.find('"#', pos + 2)
            pos = end + 2 if end >= 0 else len(source)
        elif source[pos] == '"':
            end = end_string(source, pos)
            yield pos, source[pos:end]
            pos = end
        else:
            pos += 1

def message_key(raw):
    value, result, pos = raw[1:-1], '', 0
    interpolated = '\\(' in value
    while pos < len(value):
        if value.startswith('\\(', pos):
            pos = end_expression(value, pos + 2)
            result += '%@'
        elif value[pos] == '\\' and pos + 1 < len(value):
            result += {'n': '\n', 't': '\t', 'r': '\r'}.get(value[pos + 1], value[pos + 1])
            pos += 2
        else:
            result += '%%' if interpolated and value[pos] == '%' else value[pos]
            pos += 1
    return result

checked = set()
def require(key, location):
    if not HAN.search(key):
        return
    checked.add(key)
    if key not in catalog:
        errors.append(f'Missing English key at {location}: {key!r}')

for path in (ROOT / 'Sources').rglob('*.swift'):
    source = path.read_text()
    for pos, raw in literals(source):
        if raw.startswith('"""'):
            continue
        prefix = source[max(0, pos - 200):pos]
        if re.search(r'(?:Native|Module)Localization\.text\(\s*$', prefix):
            require(message_key(raw), path.name)
        elif '\\(' not in raw and re.search(
            r'\b(?:Text|Label|Button|Menu|Picker|TextField|Toggle|Section|LabeledContent|help|accessibilityLabel|accessibilityHint)\(\s*$', prefix
        ):
            require(message_key(raw), path.name)

class ChromeParser(HTMLParser):
    def __init__(self, location):
        super().__init__()
        self.location, self.skip = location, 0
    def handle_starttag(self, tag, attributes):
        if tag in ('script', 'style'):
            self.skip += 1
        for name, value in attributes:
            if name in ('title', 'aria-label', 'placeholder', 'alt') and value:
                require(value, self.location)
    def handle_endtag(self, tag):
        if tag in ('script', 'style'):
            self.skip = max(0, self.skip - 1)
    def handle_data(self, value):
        if not self.skip and value.strip():
            require(value.strip(), self.location)

for path in list(RESOURCES.glob('*.html')) + [ROOT / 'Whiteboard/index.html']:
    ChromeParser(path.name).feed(path.read_text())
for path in list(RESOURCES.glob('*.js')) + [RESOURCES / 'RichArticleEditor.html', ROOT / 'Whiteboard/editor.jsx']:
    source = path.read_text()
    if path.suffix == '.html':
        source = source[source.index('<script>') + 8:source.rindex('</script>')]
    if path.suffix == '.jsx':
        for value in re.findall(r'>([^<>{}]*[\u3400-\u9fff][^<>{}]*)<', source):
            require(value.strip(), path.name)
    for match in re.finditer(r"'(?:\\.|[^'\\])*'|\"(?:\\.|[^\"\\])*\"", source):
        value = match.group()[1:-1]
        if not HAN.search(value):
            continue
        prefix = source[source.rfind('\n', 0, match.start()) + 1:match.start()]
        if prefix.lstrip().startswith('//') or re.search(r'aliases:\s*$', prefix):
            continue
        if '<' in value:
            ChromeParser(path.name).feed(value)
        else:
            require(value, path.name)

if errors:
    raise SystemExit('\n'.join(dict.fromkeys(errors)))
print(f'PASS: {len(catalog)} English entries; {len(checked)} native/web keys; format placeholders and translations verified')
