import assert from 'node:assert/strict';
import test from 'node:test';
import { searchArticles, searchText } from '../src/article-search.js';

test('offline article search returns readable snippets and handles same-prefix directories', () => {
  const body = '这是一段超过摘要长度的正文。'.repeat(10) + '\nCafe\u0301   访谈记录。' + '这是后续段落。'.repeat(10);
  const articles = [
    { title: '会议', sourceRelativePath: '工作/专题/会议.md', format: 'text', body },
    { title: '新闻', sourceRelativePath: '工作汇总/新闻.md', format: 'text', body },
    { title: '另一份 Café 访谈', sourceRelativePath: '生活/采访.md', format: 'text', body: '' },
  ];
  const query = searchText('  CAFÉ   访谈  ');
  const results = searchArticles(articles, query, '工作');
  assert.deepEqual([...results.keys()], [articles[0]]);
  assert.match(results.get(articles[0]), /^….*Café 访谈.*…$/);
  assert.equal(searchArticles(articles, query).size, 3);
});
