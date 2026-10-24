import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

// Exercise the shipping localization runtime without launching a browser or app.
class Element {
  nodeType = 1;
  isConnected = true;
  childNodes = [];
  attributes = new Map();
  constructor(tag, attributes = {}, children = []) {
    this.tag = tag;
    this.attributes = new Map(Object.entries(attributes));
    this.childNodes = children;
  }
  matches() { return ['script', 'style', 'textarea'].includes(this.tag) || this.attributes.has('data-user-content'); }
  hasAttribute(name) { return this.attributes.has(name); }
  getAttribute(name) { return this.attributes.get(name); }
  setAttribute(name, value) { this.attributes.set(name, value); }
}
const textNode = value => ({ nodeType: 3, nodeValue: value, isConnected: true });
const chrome = textNode('  保存  '), userText = textNode('保存');
const field = new Element('input', { placeholder: '写下想法…', 'aria-label': '便签内容' });
const body = new Element('body', {}, [chrome, field, new Element('article', { 'data-user-content': '' }, [userText])]);
const styles = new Map();
const document = { documentElement: { style: { setProperty: (key, value) => styles.set(key, value) } } };
const events = [];
const window = { dispatchEvent: event => events.push(event.type) };
const context = vm.createContext({ window, document, CustomEvent: class { constructor(type, init) { this.type = type; this.detail = init.detail; } } });
const source = await readFile(new URL('../Sources/LeonBook/Resources/WebLocalization.js', import.meta.url), 'utf8');
vm.runInContext(source, context);
const l10n = window.LeonL10n;
const strings = {
  '保存': 'Save', '写下想法…': 'Write an idea…', '便签内容': 'Note Content',
  '删除“%@”？': 'Delete “%@”?', '%@ 张卡片': '%@ cards', '反序 %@ %@': '%2$@ then %1$@',
  '开始写作，或输入 / 插入内容': 'Start writing', '添加图片说明': 'Add a caption',
};
l10n.bindChrome(body);
l10n.setLanguage({ language: 'en', strings });
assert.equal(chrome.nodeValue, '  Save  ');
assert.equal(field.getAttribute('placeholder'), 'Write an idea…');
assert.equal(field.getAttribute('aria-label'), 'Note Content');
assert.equal(userText.nodeValue, '保存', 'user content must never be translated');
assert.equal(document.documentElement.lang, 'en');
assert.equal(styles.get('--editor-placeholder'), '"Start writing"');
const title = '用户标题 %@ 100% <script>';
assert.equal(l10n.text('删除“%@”？', title), `Delete “${title}”?`);
assert.equal(l10n.text('%@ 张卡片', 0), '0 cards');
assert.equal(l10n.text('反序 %@ %@', 'first', 'second'), 'second then first');
assert.equal(l10n.text('missing translation'), 'missing translation');
// Content that has since been replaced by the application must not be reset to an old label.
chrome.nodeValue = 'Changed by the application';
l10n.setLanguage({ language: 'zh-Hans', strings: {} });
assert.equal(chrome.nodeValue, 'Changed by the application');
assert.equal(field.getAttribute('aria-label'), '便签内容');
assert.equal(userText.nodeValue, '保存');
assert.equal(l10n.text('删除“%@”？', title), `删除“${title}”？`);
assert.equal(events.length, 2);
console.log('PASS: web localization, live switching, substitutions, and user-content preservation');
