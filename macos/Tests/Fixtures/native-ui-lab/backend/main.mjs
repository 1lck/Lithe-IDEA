// Data and actions only: every visible control is rendered by Lithe.
import { setTimeout as delay } from 'node:timers/promises';
import { createBackend, PluginError } from './vendor/lithe-plugin-sdk/src/index.mjs';

const backend = createBackend({ name: 'native-ui-lab', version: '0.3.4' });
backend.build.model(() => ({ projects: [{ name: 'UI Lab', path: '.' }] }));
backend.build.dependencies(() => ({ dependencies: [] }));

for (const kind of ['tree', 'list']) {
  let nodes;
  let sequence = 0;
  let sourceFailure = false;
  let invalid = false;
  const reset = () => {
    sequence = 0;
    sourceFailure = invalid = false;
    nodes = kind === 'tree'
      ? [{ id: 'root', label: '展开我 · 四层树', children: [
          { id: 'group', label: '第二层 · 可展开', children: [
            { id: 'nested', label: '第三层', children: [{ id: 'deep-leaf', label: '第四层 · 最深叶节点' }] },
            { id: 'unicode', label: '中文 / English / 😀🚀 / <>&' },
          ] },
          { id: 'long', label: '长标签截断验收：' + '中文与 English 混排 — '.repeat(12) },
          { id: 'empty-children', label: '显式空 children 的叶节点', children: [] },
        ] }, { id: 'other', label: '另一个根节点' }]
      : Array.from({ length: 30 }, (_, i) => ({ id: `row-${i + 1}`, label: `${i + 1} · ${['中文条目', 'English item', 'Emoji 😀🚀', 'Symbols <>&'][i % 4]}` }));
  };
  const flatten = (items) => items.flatMap((node) => [node, ...flatten(node.children ?? [])]);
  const selected = (id) => {
    const node = flatten(nodes).find((node) => node.id === id);
    if (!node) throw new PluginError('lab.selection', '请先选择一个当前存在的节点。');
    return node;
  };
  reset();
  backend.function(`${kind}.nodes`, () => {
    if (sourceFailure) throw new PluginError('lab.source', '预期的数据加载失败：右键选择“重置”恢复。');
    return { nodes: invalid ? [{ id: 'duplicate', label: '非法 A' }, { id: 'duplicate', label: '非法 B' }] : nodes };
  });
  const action = (id, handler) => backend.function(`${kind}.${id}`, handler);
  action('inspect', ({ selectedID }) => ({ message: `检查成功：${selected(selectedID).label} [${selectedID}]` }));
  action('reset', () => { reset(); return { message: '已重置。树与列表的数据彼此独立；状态只保留到 Provider 退出。' }; });
  action('rename', ({ selectedID }) => {
    selected(selectedID).label += ' ✓';
    return { message: `已修改 ${selectedID} 的标签，稳定 ID 不变，选中应保留。` };
  });
  action('add', () => {
    const id = `added-${++sequence}`;
    nodes.push({ id, label: `新增节点 ${sequence}` });
    return { message: `已添加 ${id}，请滚动到底部检查。` };
  });
  action('remove', ({ selectedID }) => {
    selected(selectedID);
    const remove = (items) => items.filter((node) => node.id !== selectedID).map((node) =>
      node.children ? { ...node, children: remove(node.children) } : node);
    nodes = remove(nodes);
    return { message: `已移除 ${selectedID} 及其子树，失效的选中应清除。` };
  });
  action('reverse', () => { nodes.reverse(); return { message: '根节点顺序已反转，仍存在的选中项应保留。' }; });
  action('empty', () => {
    if (nodes.length) nodes = []; else reset();
    return { message: nodes.length ? '已恢复默认数据。' : '已切换空数据；使用顶部“重置”恢复。' };
  });
  action('large', () => {
    reset();
    nodes = Array.from({ length: 600 }, (_, i) => ({ id: `bulk-${i}`, label: `${String(i + 1).padStart(3, '0')} · 滚动验收 / English / 😀`,
      ...(kind === 'tree' ? { children: [{ id: `bulk-${i}-child`, label: `子节点 ${i + 1}` }] } : {}) }));
    return { message: '已加载 600 项；树另含 600 个子节点。使用“重置”恢复。' };
  });
  action('slow', async (_, { signal, progress }) => {
    progress({ message: '慢动作已开始', percentage: 0 });
    await delay(3000, undefined, { signal });
    return { message: '3 秒慢动作完成。等待期间操作禁用；可测试隐藏面板后的取消。' };
  });
  action('fail', () => { throw new PluginError('lab.expected', '预期的动作失败：原有行应保留，点击刷新可恢复。'); });
  action('sourceError', () => { sourceFailure = true; return { message: '下一次数据读取会失败；顶部“重置”恢复。' }; });
  action('invalid', () => { invalid = true; return { message: '返回重复 ID：宿主应拒绝数据并保留之前的行；顶部“重置”恢复。' }; });
}

backend.function('buttons.inspect', () => ({ message: 'UI Lab 0.3.4：按钮动作已执行；外观完全由当前 IDE 宿主公共样式绘制。' }));
backend.function('form.nodes', () => ({ nodes: [] }));
backend.function('form.changed', ({ values }) => {
  if (!values || typeof values.name !== 'string' || typeof values.query !== 'string'
      || !['dev', 'test', 'prod'].includes(values.environment) || typeof values.notify !== 'boolean'
      || typeof values.offline !== 'boolean' || typeof values.search !== 'string' || typeof values.notes !== 'string'
      || !['fast', 'safe', 'debug'].includes(values.mode) || typeof values.concurrency !== 'number'
      || values.concurrency < 1 || values.concurrency > 8) {
    throw new PluginError('lab.form', '控件值类型不正确。');
  }
  return { message: `已收到：${JSON.stringify(values)}` };
});

backend.function('form.slow', async (_, { signal, progress }) => {
  progress({ message: '表单慢提交已开始', percentage: 0 });
  await delay(3000, undefined, { signal });
  return { message: '表单慢提交完成。' };
});
backend.function('form.fail', () => { throw new PluginError('lab.form.expected', '预期提交失败：本地值应保留，再次提交可恢复。'); });

await backend.listen();
